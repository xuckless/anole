-- wrk's summary as one JSON line ("JSON {...}"), for benchctl.
done = function(summary, latency, requests)
  local e = summary.errors
  io.write(string.format(
    'JSON {"requests":%d,"duration_us":%d,"bytes":%d,"errors":%d,"non2xx":%d,' ..
    '"mean_us":%.1f,"max_us":%d,"p50_us":%d,"p90_us":%d,"p99_us":%d,"p999_us":%d}\n',
    summary.requests, summary.duration, summary.bytes,
    e.connect + e.read + e.write + e.timeout, e.status,
    latency.mean, latency.max, latency:percentile(50), latency:percentile(90),
    latency:percentile(99), latency:percentile(99.9)))
end
