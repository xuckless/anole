# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "1bcaac54cef8b75551a866c377ae16eb89c94340",
  "date": "2026-10-19T04:22:33Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "9a56f4781d0b", "fiber": "8e5f66a160d8", "gohttp": "9ad658cb5624", "axum": "bd66830683f6", "express": "1d4bcf0d5e69", "fastify": "378067d992ac", "fastapi": "eef6cec895c3", "nginx": "6f4c687d31a4", "gohttp-wt": "b71f8fab8b9c", "axum-wt": "5d1cb4993bce", "fastify-wt": "f85fb74f37fd", "fastapi-wt": "bf0d6a4cc457", "loadgen": "4b0738a9d98f"}
}

```

## The $12 server challenge (Postgres)

load.js's users (feed, think, post, think, 15% like, 2% write, idle), added in steps; each step's window must keep p95 < 500 ms, p99 < 1 s and < 1% errors. Score: the most users that passed. Server memory is the peak in that step.

### 1cpu

| Server | Score (users) | req/s at score | p95 ms | p99 ms | memory MB | cores busy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| anole | **30,000** | 3,177 | 2 | 112 | 1732 | 0.10 |
| fiber | **40,000** | 4,240 | 2 | 3 | 2035 | 0.17 |
| gohttp | **50,000** | 5,295 | 2 | 4 | 1715 | 0.24 |
| axum | **50,000** | 5,292 | 2 | 3 | 1961 | 0.26 |
| express | **80,000** | 8,484 | 4 | 8 | 1470 | 0.60 |
| fastify | **80,000** | 8,486 | 3 | 5 | 1332 | 0.48 |
| fastapi | **25,000** | 2,644 | 2 | 96 | 425 | 0.63 |

