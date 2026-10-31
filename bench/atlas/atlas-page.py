#!/usr/bin/env python3
"""The atlas's index page: every cell's numbers, top-5 self-time symbols,
CPU split, memory per request and RSS, with its flame graphs loaded inline
from the published files beside the page.

  atlas-page.py <atlas dir> <out.html> <title> <subtitle>
"""
import html, json, os, sys

GROUPS = [
    ("HTTP/1.1 baseline · #103 console", ["h1-plain", "h1-json", "h1-json-noconsole"],
     "Netfilter on loopback is the largest single cost (35-37% of the server's CPU). User space runs about 9.2k instructions per JSON request. The console costs nothing measurable: 9,243 against 9,242."),
    ("#101 json-comp · K4", ["h1-jsoncomp-gzip", "h1-jsoncomp-br", "h1-jsoncomp-zstd"],
     "Each response builds a fresh encoder at a high level. gzip takes a 296 KB deflate state per request. Brotli spends 48% in CreateBackwardReferencesNH40. zstd allocates about 770 KB per request and spends 20% zeroing its match state. Fix: low levels for dynamic bodies, one encoder per executor."),
    ("#130 TLS h1", ["tls-h1-json"],
     "87% of cleartext's rate, about 7k extra user instructions per request, BoringSSL 8%. The BIO write mallocs per write (1.2-4.9 KB per request)."),
    ("HTTP/2 takeover", ["h2c-json-m10", "h2c-json-m64"],
     "The gate's baseline: 16.9k user instructions per request at m10 and 19.3k at m64. nghttp2 is 18-22% of CPU, the h2 glue 14-17%, the arena 11-14% (about 16 calls per request, mostly onHeader and serveStream). m64 does more work per request than m10."),
    ("#102 static over h2 · K7", ["h2-static"],
     "The body is copied three times (into the stream queue, out to nghttp2, into the TLS BIO), with 41 KB of arena per request. On epoll, file reads go through the blocking pool: 11 context switches per request, 35% slower than io_uring."),
    ("#100 HTTP/3 · #151 · H3-A", ["h3-json", "h3-static", "h3-post"],
     "nghttp3 is 21% of h3-json, past its 15% takeover trigger. memcpy is 8.0-8.2% of h3-post, at its 8% trigger. Sends are already batched with sendmmsg and GSO. h3-static has a flat profile at 156k instructions per request, and on epoll its file reads go through the blocking pool."),
    ("#99 gRPC unary", ["grpc-unary"],
     "About 110 KB allocated per call for a 9-byte body, mostly under nghttp2 → h2.Engine.onDataChunk. Stream arenas keep their high-water mark after reset, so RSS reaches 0.84-0.95 GB at 25,600 calls in flight."),
    ("#97 idle HTTP/2 tasks", ["sse-h1", "sse-h2c"],
     "Idle subscribers settle at about 4.7-5.0 KB of RSS each over h1 and 48-51 KB over h2c, about 10 times more. h1 gives back the connection ramp's memory; h2c keeps it. Per subscriber, h2c takes 3 coroutine stacks and 4 task-pool slots against 2 and 2, and maps 2.6 MB of stack space against 1.6 MB."),
    ("#147 raw TCP", ["net-tcp"],
     "User space is lean (1.7-2.1k instructions per message, no allocation). Netfilter is 39-43% of CPU. The second recvfrom needs a syscall count, not a profile."),
]
FAMILY = {
    "kernel": ("kernel net", "kernel netfilter", "kernel io_uring", "kernel file I/O", "kernel sched/epoll", "kernel syscall entry", "kernel memory", "kernel copy", "kernel other"),
    "crypto": ("BoringSSL", "tls glue"),
    "protocol": ("nghttp2", "ngtcp2", "nghttp3", "h2 glue", "h3/quic glue", "grpc"),
    "payload": ("compression", "json"),
    "memory": ("memcpy/memset", "malloc (libc)", "zig heap"),
    "anole": ("zio runtime", "anole http/net", "other user", "unknown"),
}


def slim(r):
    rss = r.get("rss", {})
    t, mb = rss.get("t", []), rss.get("rss_mb", [])
    step = max(1, len(t) // 120)
    return {
        "cell": r["cell"], "backend": r["backend"], "count": r.get("count", {}),
        "kernel_pct": r.get("cpu", {}).get("kernel_pct"), "components": r.get("cpu", {}).get("components", {}),
        "top_self": r.get("cpu", {}).get("top_self", []), "offcpu": r.get("offcpu", {}).get("top", [])[:3],
        "mem": {k: r.get("mem", {}).get(k) for k in ("per_req", "top_alloc", "top_held", "held_truncated", "window_requests")},
        "probes_held": r.get("mem", {}).get("probes", {}).get("held"),
        "subscribers": r.get("subscribers"),
        "rss": {"t": t[::step], "mb": mb[::step], "peak": rss.get("peak_rss_mb"), "cg_peak": rss.get("memory_peak_mb"),
                "settled": rss.get("settled_rss_mb"), "start": rss.get("start_rss_mb")},
        "flames": r.get("flames", {}),
    }


def main(d, out, title, sub):
    rows = [slim(r) for r in json.load(open(os.path.join(d, "index.json")))]
    key = open(os.path.join(d, "key.txt")).read()
    keep = ("anole_ref", "side.atlas.binary_sha256", "kernel", "cpu_model", "microcode", "governor", "sut_cpus", "load_cpus", "perf", "h2load", "bpftrace", "date_utc", "deviation")
    keyl = [l for l in key.splitlines() if l.split("=", 1)[0] in keep]
    data = {"rows": rows, "groups": GROUPS, "family": FAMILY, "key": keyl}
    page = open(os.path.join(os.path.dirname(__file__), "atlas-page.html")).read()
    page = page.replace("__TITLE__", html.escape(title)).replace("__SUB__", html.escape(sub))
    page = page.replace("__DATA__", json.dumps(data, separators=(",", ":")).replace("</", "<\\/"))
    open(out, "w").write(page)


if __name__ == "__main__":
    main(*sys.argv[1:5])
