#!/usr/bin/env python3
"""Parse conns-ab.sh results.
  conns-summary.py one <case-dir>     # one line for the log
  conns-summary.py table <out-dir>    # medians per backend, case and side
"""
import glob, json, os, re, statistics, sys


def ms(v, unit):
    return float(v) * {"us": 0.001, "ms": 1, "s": 1000, "m": 60000}[unit]


def parse(d):
    r = {}
    t = open(os.path.join(d, "load.txt"), errors="replace").read()
    if m := re.search(r"Requests/sec:\s+([\d.]+)", t):
        r["rps"] = float(m.group(1))
        for p in ("50", "99"):
            if m := re.search(rf"^\s+{p}%\s+([\d.]+)(us|ms|s|m)\b", t, re.M):
                r[f"p{p}_ms"] = ms(*m.groups())
        m = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", t)
        r["timeouts"] = int(m.group(4)) if m else 0
        r["sock_errors"] = sum(int(x) for x in m.groups()[:3]) if m else 0
        m = re.search(r"Non-2xx or 3xx responses: (\d+)", t)
        r["non2xx"] = int(m.group(1)) if m else 0
    elif m := re.search(r"finished in [\d.]+\w+, ([\d.]+) req/s", t):
        r["rps"] = float(m.group(1))
        if m := re.search(r"time for request:\s+([\d.]+)(us|ms|s)\s+([\d.]+)(us|ms|s)\s+([\d.]+)(us|ms|s)", t):
            r["mean_ms"] = ms(m.group(5), m.group(6))
            r["max_ms"] = ms(m.group(3), m.group(4))
        if m := re.search(r"percentiles: p50 (\d+) us p99 (\d+) us", t):
            r["p50_ms"], r["p99_ms"] = int(m.group(1)) / 1000, int(m.group(2)) / 1000
        if m := re.search(r"requests: \d+ total, \d+ started, \d+ done, (\d+) succeeded, (\d+) failed, (\d+) errored, (\d+) timeout", t):
            r["failed"], r["timeouts"] = int(m.group(2)) + int(m.group(3)), int(m.group(4))
    try:
        r["recvq_peak"] = int(open(os.path.join(d, "recvq-peak")).read().strip() or 0)
    except (OSError, ValueError):
        pass
    try:
        r["mem_peak_mb"] = int(open(os.path.join(d, "mem-peak")).read()) / 2**20
    except (OSError, ValueError):
        pass
    try:
        r["state"] = open(os.path.join(d, "state")).read().strip()
    except OSError:
        pass
    pk = os.path.join(d, "park.json")
    if os.path.exists(pk):
        try:
            r["wake"] = json.loads(open(pk).read())
        except ValueError:
            r["wake"] = {"error": open(os.path.join(d, "park.err")).read()[-200:]}
    return r


def one(d):
    r = parse(d)
    s = f"{r.get('rps', 0):,.0f} req/s"
    if "p50_ms" in r:
        s += f", p50 {r['p50_ms']:.2f} ms, p99 {r.get('p99_ms', 0):.2f} ms"
    if "mean_ms" in r and "p50_ms" not in r:
        s += f", mean {r['mean_ms']:.2f} ms, max {r.get('max_ms', 0):.1f} ms"
    s += f", timeouts {r.get('timeouts', 0)}, Recv-Q peak {r.get('recvq_peak', '?')}, mem {r.get('mem_peak_mb', 0):.0f} MB"
    if w := r.get("wake"):
        s += f"; wake {w.get('answered')}/{w.get('parked')} p50 {w.get('p50_ms', 0):.1f} ms p99 {w.get('p99_ms', 0):.1f} ms max {w.get('max_ms', 0):.1f} ms timeouts {w.get('timeouts')}"
    if r.get("state", "").split()[0:1] != ["running"]:
        s += f" [{r.get('state')}]"
    return s


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def table(out):
    rows = ["| backend | case | side | req/s | p50 ms | p99 ms | timeouts | Recv-Q peak | mem MB | wake p50 / p99 / max ms (timeouts) |",
            "|---|---|---|---|---|---|---|---|---|---|"]
    f = lambda v, p=0: "–" if v is None else f"{v:,.{p}f}"
    for be in ("epoll", "uring"):
        for case in ("c4096", "c10000", "c25000", "park", "c256", "h2c", "h3"):
            for side in ("a", "b"):
                runs = [parse(d) for d in sorted(glob.glob(os.path.join(out, be, case, f"{side}-r*")))]
                if not runs:
                    continue
                g = lambda k: med([r.get(k) for r in runs])
                wake = ""
                ws = [r["wake"] for r in runs if isinstance(r.get("wake"), dict) and "p50_ms" in r["wake"]]
                if ws:
                    wake = f"{f(med([w['p50_ms'] for w in ws]), 1)} / {f(med([w['p99_ms'] for w in ws]), 1)} / {f(med([w['max_ms'] for w in ws]), 1)} ({f(med([w['timeouts'] for w in ws]))})"
                p50 = g("p50_ms") if g("p50_ms") is not None else g("mean_ms")
                rows.append(f"| {be} | {case} | {side.upper()} | {f(g('rps'))} | {f(p50, 2)} | {f(g('p99_ms'), 2)} | {f(g('timeouts'))} | "
                            f"{f(g('recvq_peak'))} | {f(g('mem_peak_mb'))} | {wake} |")
    n = max((len(glob.glob(os.path.join(d, "a-r*"))) for d in glob.glob(os.path.join(out, "*", "*"))), default=0)
    print(f"Medians of {n} runs per side. h2c and h3 (h2load): percentiles from h2load's per-request log.\n")
    print("\n".join(rows))


if __name__ == "__main__":
    {"one": lambda: print(one(sys.argv[2])), "table": lambda: table(sys.argv[2])}[sys.argv[1]]()
