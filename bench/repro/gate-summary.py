#!/usr/bin/env python3
"""Parse gate.sh results.
  gate-summary.py one <run-dir>     # one line for the log
  gate-summary.py table <out-dir>   # medians per backend, case and side, each side against the first
"""
import glob, json, os, re, statistics, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
conns = __import__("conns-summary")


def parse(d):
    r = conns.parse(d)
    p = os.path.join(d, "wsecho.json")
    if os.path.exists(p):
        try:
            j = json.load(open(p))
            r.update(rps=j["msgs_per_s"], p50_ms=j["rtt"]["p50_ms"], p99_ms=j["rtt"]["p99_ms"], errors=j["errors"])
        except (ValueError, KeyError):
            r["rps"] = 0
    try:
        usec = int(open(os.path.join(d, "cpu-usec")).read())
        if r.get("rps"):
            r["cpu_us_per_req"] = usec / (r["rps"] * float(os.environ.get("DUR", 30)))
    except (OSError, ValueError):
        pass
    return r


def one(d):
    r = parse(d)
    s = f"{r.get('rps', 0):,.0f}/s, p50 {r.get('p50_ms', 0):.2f} ms, p99 {r.get('p99_ms', 0):.2f} ms"
    s += f", errors {r.get('timeouts', 0) + r.get('sock_errors', 0) + r.get('non2xx', 0) + r.get('failed', 0) + r.get('errors', 0)}"
    s += f", mem {r.get('mem_peak_mb', 0):.0f} MB"
    if r.get("state", "").split()[0:1] != ["running"]:
        s += f" [{r.get('state')}]"
    return s


def table(out):
    sides = [l.split("=", 1)[0] for l in open(os.path.join(out, "sides.txt")).read().split()]
    f = lambda v, p=0: "–" if v is None else f"{v:,.{p}f}"
    rows = ["| backend | case | side | req/s | vs " + sides[0] + " | p50 ms | p99 ms | µs CPU/req | mem MB | runs |", "|---|---|---|---|---|---|---|---|---|---|"]
    for be in ("epoll", "uring"):
        for case in ("plain", "json", "h2c", "h2c64", "h3", "asyncdb", "wsecho"):
            base = None
            for side in sides:
                runs = [parse(d) for d in sorted(glob.glob(os.path.join(out, be, case, f"{side}-r*")))]
                if not runs:
                    continue
                g = lambda k: conns.med([x.get(k) for x in runs])
                rps = g("rps")
                if base is None:
                    base = rps
                rel = f"{rps / base:.3f}" if base and rps else "–"
                runs_s = " / ".join(f"{x.get('rps', 0) / 1000:.1f}k" for x in runs)
                rows.append(f"| {be} | {case} | {side} | {f(rps)} | {rel} | {f(g('p50_ms'), 2)} | {f(g('p99_ms'), 2)} | {f(g('cpu_us_per_req'), 3)} | {f(g('mem_peak_mb'))} | {runs_s} |")
    print("Medians per side; h2c and h3 percentiles from h2load's per-request log, wsecho from its RTT samples.\n")
    print("\n".join(rows))


if __name__ == "__main__":
    {"one": lambda: print(one(sys.argv[2])), "table": lambda: table(sys.argv[2])}[sys.argv[1]]()
