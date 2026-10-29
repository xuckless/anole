#!/usr/bin/env python3
"""Summaries for bench/repro/netem.sh (h2load output).

  netem-summary.py one  <run dir>     one run
  netem-summary.py cell <cell dir>    medians per protocol, h3 against h1
  netem-summary.py table <netem dir>  Markdown table
"""
import os, re, statistics, sys

TARGET = 0.10  # h3 within 10% of h1


def run(d):
    t = open(os.path.join(d, "load.txt")).read()
    m = re.search(r"finished in ([\d.]+)(ms|s), ([\d.]+) req/s, ([\d.]+)([KMG]?)B/s", t)
    unit = {"": 1e-6, "K": 1e-3, "M": 1, "G": 1e3}[m.group(5)]
    mean = re.search(r"time for request:\s+\S+\s+\S+\s+([\d.]+)(us|ms|s)", t)
    ms = float(mean.group(1)) * {"us": 1e-3, "ms": 1, "s": 1e3}[mean.group(2)]
    ok = re.search(r"requests: \d+ total, \d+ started, \d+ done, (\d+) succeeded, (\d+) failed", t)
    cpu = int(open(os.path.join(d, "cpu-usec")).read()) / 1e6
    secs = float(m.group(1)) / (1000 if m.group(2) == "ms" else 1)
    return {"secs": secs, "rps": float(m.group(3)), "mbs": float(m.group(4)) * unit,
            "mean_ms": ms, "ok": int(ok.group(1)), "failed": int(ok.group(2)), "cpu_s": cpu}


def one(d):
    r = run(d)
    return (f"{r['mbs']:.1f} MB/s, mean {r['mean_ms']:.0f} ms per file, {r['secs']:.2f} s, "
            f"server CPU {r['cpu_s']:.2f} s, ok {r['ok']} failed {r['failed']}")


def cell(cd):
    sides = {}
    for e in sorted(os.listdir(cd)):
        p = e.partition("-r")[0]
        try:
            sides.setdefault(p, []).append(run(os.path.join(cd, e)))
        except (FileNotFoundError, AttributeError, ValueError):
            pass
    return {p: {k: statistics.median(x[k] for x in rs) for k in ("mbs", "mean_ms", "cpu_s")}
            | {"n": len(rs), "failed": sum(x["failed"] for x in rs), "runs": [round(x["mbs"], 1) for x in rs]}
            for p, rs in sides.items()}


def cell_line(cd):
    med = cell(cd)
    parts = [f"{p}: {m['mbs']:.1f} MB/s, mean {m['mean_ms']:.0f} ms/file, CPU {m['cpu_s']:.2f} s (n={m['n']}, runs {m['runs']}, failed {m['failed']})"
             for p, m in sorted(med.items())]
    for p in ("h2", "h3"):
        if "h1" in med and p in med and med["h1"]["mbs"]:
            dv = med[p]["mbs"] / med["h1"]["mbs"] - 1
            parts.append(f"{p} vs h1: {dv * 100:+.1f}% -> {'within 10%' if dv >= -TARGET else 'OUTSIDE 10%'}")
    return "; ".join(parts)


def table(root):
    rows = ["| backend | size | conns | h1 MB/s | h2 MB/s | h3 MB/s | h2 vs h1 | h3 vs h1 | h1 ms/file | h2 ms/file | h3 ms/file | h1 / h2 / h3 CPU s | target (h2, h3) |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for be in ("epoll", "uring"):
        bd = os.path.join(root, be)
        if not os.path.isdir(bd):
            continue
        for c in sorted(os.listdir(bd), key=lambda c: (int(c.split("m-")[0]), int(c.split("-c")[1]))):
            med = cell(os.path.join(bd, c))
            if "h1" not in med:
                continue
            none = {"mbs": 0.0, "mean_ms": 0.0, "cpu_s": 0.0}
            a, h2, h3 = med["h1"], med.get("h2", none), med.get("h3", none)
            d2, d3 = h2["mbs"] / a["mbs"] - 1, h3["mbs"] / a["mbs"] - 1
            met = lambda d: "met" if d >= -TARGET else "**missed**"
            sz, n = c.split("-c")
            rows.append(f"| {be} | {sz.upper()}iB | {n} | {a['mbs']:.1f} | {h2['mbs']:.1f} | {h3['mbs']:.1f} | {d2 * 100:+.1f}% | {d3 * 100:+.1f}% | "
                        f"{a['mean_ms']:.0f} | {h2['mean_ms']:.0f} | {h3['mean_ms']:.0f} | {a['cpu_s']:.2f} / {h2['cpu_s']:.2f} / {h3['cpu_s']:.2f} | "
                        f"{met(d2)}, {met(d3)} |")
    return "\n".join(rows)


if __name__ == "__main__":
    print({"one": one, "cell": cell_line, "table": table}[sys.argv[1]](sys.argv[2]))
