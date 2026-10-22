# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "41df5e044b6f5a5bf1f59b30c536c825ffc814dd",
  "date": "2026-10-22T09:52:13Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@main": "aac99237993c", "loadgen": "75b50004f33c"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h3 |
| --- | ---: |
| anole@main | **387,781** mean 1.65 ms [69 MB, 1.00] |
| anole@qfix | **398,129** mean 1.61 ms [51 MB, 1.00] |

### 1cpu, GET /json

| Server | h3 |
| --- | ---: |
| anole@main | **375,953** mean 1.70 ms [82 MB, 1.00] |
| anole@qfix | **381,693** mean 1.68 ms [72 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h3 |
| --- | ---: |
| anole@main | **1,409,787** mean 0.43 ms [46 MB, 3.99] |
| anole@qfix | **1,426,824** mean 0.42 ms [44 MB, 3.99] |

### 4cpu, GET /json

| Server | h3 |
| --- | ---: |
| anole@main | **1,322,325** mean 0.49 ms [52 MB, 3.99] |
| anole@qfix | **1,266,751** mean 0.51 ms [57 MB, 3.99] |

