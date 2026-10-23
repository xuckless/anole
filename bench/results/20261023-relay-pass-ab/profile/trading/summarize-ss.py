#!/usr/bin/env python3
"""Per-socket queue depth from the ss -tmni samples (ss/t*.txt.gz), split into
trade sockets (/ws/trade: the server receives orders) and feed sockets."""
import glob, gzip, re, statistics, sys

def parse(path):
    socks, cur = {}, None
    for line in gzip.open(path, "rt", errors="replace"):
        if line.startswith("ESTAB"):
            f = line.split()
            cur = {"rq": int(f[1]), "sq": int(f[2]), "local": f[3], "peer": f[4]}
            socks[(f[3], f[4])] = cur
        elif cur is not None:
            m = re.search(r"bytes_received:(\d+)", line)
            cur["rx"] = int(m.group(1)) if m else 0
    return socks

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else 0

for d in sys.argv[1:]:
    acc = {k: [] for k in ("trade_srv_rq", "trade_srv_sq", "trade_cli_rq", "feed_srv_sq", "feed_cli_rq")}
    ntrade = nfeed = 0
    for f in sorted(glob.glob(f"{d}/ss/t*.txt.gz")):
        s = parse(f)
        for (loc, peer), v in s.items():
            if not loc.endswith(":8080"):
                continue
            cli = s.get((peer, loc), {})
            if v.get("rx", 0) > 5000:  # orders arrive: a /ws/trade socket
                ntrade += 1
                acc["trade_srv_rq"].append(v["rq"]); acc["trade_srv_sq"].append(v["sq"]); acc["trade_cli_rq"].append(cli.get("rq", 0))
            else:
                nfeed += 1
                acc["feed_srv_sq"].append(v["sq"]); acc["feed_cli_rq"].append(cli.get("rq", 0))
    n = len(glob.glob(f"{d}/ss/t*.txt.gz"))
    print(f"== {d}: {n} samples, {ntrade // max(1, n)} trade and {nfeed // max(1, n)} feed sockets per sample")
    for k, xs in acc.items():
        nz = sum(1 for x in xs if x > 0)
        print(f"  {k:13s} mean {statistics.mean(xs) if xs else 0:10.0f} B  p50 {pct(xs, .5):8d}  p99 {pct(xs, .99):9d}  max {max(xs) if xs else 0:9d}  non-zero {100 * nz / max(1, len(xs)):5.1f}%")
