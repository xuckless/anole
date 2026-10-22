#!/usr/bin/env python3
"""Summarizes the release-0.1.1 A/B logs (ab011.sh): per profile and
connection count, each invocation's median of its 3 runs, then the median
over rounds, with the per-round numbers. Latency: gcannon's p99, h2load's
mean (h2load reports no percentiles)."""
import glob, os, re, statistics as st, sys

d = sys.argv[1]
names = {"anole-ma": "A main 938f258", "anole-rc": "B release-0.1.1 18bbe33", "anole-rn": "B reset_session=false"}

def unit(v, u):
    v = float(v)
    return v * {"": 1, "K": 1e3, "M": 1e6, "G": 1e9}[u]

def lat_ms(s):
    m = re.match(r"([\d.]+)(us|ms|s)$", s)
    if not m: return None
    v = float(m.group(1))
    return v / 1000 if m.group(2) == "us" else v * 1000 if m.group(2) == "s" else v

data = {}  # (profile, conns) -> fw -> round -> list of (rps, lat)
for f in sorted(glob.glob(os.path.join(d, "r*-*.log"))):
    m = re.match(r"r(\d)-(.+)-(anole-\w\w)\.log", os.path.basename(f))
    rnd, prof, fw = int(m.group(1)), m.group(2), m.group(3)
    conns = None
    runs = []
    for line in open(f, errors="replace"):
        h = re.match(r"=== anole-\w\w / [\w-]+ / (\d+)c", line)
        if h:
            conns = int(h.group(1)); continue
        if conns is None: continue
        g = re.search(r"finished in [\d.]+s, ([\d.]+) req/s", line)
        if g:
            runs.append([conns, float(g.group(1)), None]); continue
        g = re.match(r"\s*time for request:\s+\S+\s+\S+\s+(\S+)", line)
        if g and runs and runs[-1][2] is None:
            runs[-1][2] = lat_ms(g.group(1)); continue
        g = re.match(r"\s*Latency\s+[\d.]+(?:us|ms|s)\s+\S+\s+\S+\s+(\S+)", line)
        if g:
            runs.append([conns, None, lat_ms(g.group(1))]); continue
        g = re.search(r"Throughput: ([\d.]+)([KMG]?) (?:req|msg)", line)
        if g and runs and runs[-1][1] is None:
            runs[-1][1] = unit(g.group(1), g.group(2))
    for c, rps, lat in runs:
        if rps is None: continue
        data.setdefault((prof, c), {}).setdefault(fw, {}).setdefault(rnd, []).append((rps, lat))

out = []
for (prof, c) in sorted(data):
    fws = data[(prof, c)]
    lat_name = "p99" if prof in ("baseline", "echo-ws", "async-db") else "mean lat"
    out.append(f"\n### {prof}, {c} connections\n")
    out.append(f"| version | median req/s | per round (median of 3 runs) | {lat_name} | Δ vs A |")
    out.append("|---|---|---|---|---|")
    base = None
    for fw in ("anole-ma", "anole-rc", "anole-rn"):
        if fw not in fws: continue
        per = []
        lats = []
        for r in sorted(fws[fw]):
            per.append(st.median(x[0] for x in fws[fw][r]))
            ls = [x[1] for x in fws[fw][r] if x[1] is not None]
            if ls: lats.append(st.median(ls))
        med = st.median(per)
        lat = f"{st.median(lats):.2f} ms" if lats else "-"
        if fw == "anole-ma": base = med
        delta = "" if fw == "anole-ma" or not base else f"{(med / base - 1) * 100:+.1f}%"
        out.append(f"| {names[fw]} | {med:,.0f} | {' / '.join(f'{p:,.0f}' for p in per)} | {lat} | {delta} |")
print("\n".join(out))
