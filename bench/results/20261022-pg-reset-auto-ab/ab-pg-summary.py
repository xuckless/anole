#!/usr/bin/env python3
"""Summarizes the pg-reset A/B logs (ab-pg.sh). Per profile, connection count
and version: each invocation's median of its 3 runs, then the median over the
rounds, with the per-round values. async-db uses gcannon throughput and p99.
production-stack uses h2load, reads and writes separately; the total is
reads+writes per run, and the latency is h2load's mean."""
import glob, os, re, statistics as st, sys

d = sys.argv[1]
names = {"anole-pr": "v0.1.1, reset on (default)", "anole-pn": "v0.1.1, ANOLE_PG_RESET=0", "anole-pa": "#76 pg-reset-auto (5098bb5)"}
order = ["anole-pr", "anole-pn", "anole-pa"]

def ms(s):
    m = re.match(r"([\d.]+)(us|ms|s)$", s)
    v = float(m.group(1))
    return v / 1000 if m.group(2) == "us" else v * 1000 if m.group(2) == "s" else v

# (profile, conns) -> metric -> fw -> round -> [values]
data = {}
def add(prof, c, metric, fw, rnd, v):
    data.setdefault((prof, c), {}).setdefault(metric, {}).setdefault(fw, {}).setdefault(rnd, []).append(v)

for f in sorted(glob.glob(os.path.join(d, "r*-*.log"))):
    m = re.match(r"r(\d)-(.+)-(anole-\w\w)\.log", os.path.basename(f))
    rnd, prof, fw = int(m.group(1)), m.group(2), m.group(3)
    conns = sec = None
    run = {}
    def flush():
        if conns and "reads" in run and "writes" in run:
            add(prof, conns, "total req/s", fw, rnd, run["reads"] + run["writes"])
    for line in open(f, errors="replace"):
        if (h := re.match(r"=== anole-\w\w / [\w-]+ / (\d+)c", line)):
            flush(); run = {}; conns = int(h.group(1)); continue
        if (h := re.match(r"\[run \d/\d\]", line)):
            flush(); run = {}; continue
        if (h := re.match(r"=== h2load-(reads|writes) ===", line)):
            sec = h.group(1); continue
        if conns is None: continue
        if (g := re.search(r"finished in [\d.]+s, ([\d.]+) req/s", line)):
            run[sec] = float(g.group(1)); add(prof, conns, f"{sec} req/s", fw, rnd, float(g.group(1))); continue
        if (g := re.match(r"\s*time for request:\s+\S+\s+\S+\s+(\S+)", line)) and sec:
            add(prof, conns, f"{sec} mean ms", fw, rnd, ms(g.group(1))); continue
        if (g := re.match(r"\s*Latency\s+[\d.]+(?:us|ms|s)\s+\S+\s+\S+\s+(\S+)", line)):
            add(prof, conns, "p99 ms", fw, rnd, ms(g.group(1))); continue
        if (g := re.search(r"Throughput: ([\d.]+)([KMG]?) req", line)):
            add(prof, conns, "req/s", fw, rnd, float(g.group(1)) * {"": 1, "K": 1e3, "M": 1e6, "G": 1e9}[g.group(2)])
    flush()

for (prof, c) in sorted(data):
    print(f"\n### {prof}, {c} connections\n")
    for metric, fws in data[(prof, c)].items():
        print(f"\n{metric}\n\n| version | median | per round (median of 3 runs) | Δ vs reset on |\n|---|---|---|---|")
        base = None
        for fw in order:
            if fw not in fws: continue
            per = [st.median(fws[fw][r]) for r in sorted(fws[fw])]
            med = st.median(per)
            if fw == "anole-pr": base = med
            fmt = (lambda v: f"{v:,.0f}") if "req/s" in metric else (lambda v: f"{v:.2f}")
            delta = "" if fw == "anole-pr" or not base else f"{(med / base - 1) * 100:+.1f}%"
            print(f"| {names[fw]} | {fmt(med)} | {' / '.join(fmt(p) for p in per)} | {delta} |")
