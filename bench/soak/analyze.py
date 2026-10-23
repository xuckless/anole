#!/usr/bin/env python3
"""Soak results (bench/soak/run.sh).

  analyze.py rates <probe-dir> <fraction>   # per-stream rates for the soak
  analyze.py report <out-dir> [settle-s]    # Markdown summary, and summary.json; the slope leaves
                                            # out each phase's first settle-s seconds (default 60)
"""
import csv, json, os, re, sys

STREAMS = ["h1ka", "h1close", "tlsclose", "h2big", "h2cecho", "h3"]


def oha(path):
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    codes = d.get("statusCodeDistribution") or {}
    # oha cuts the requests in flight when its duration ends: not the server's errors.
    errors = {k: v for k, v in (d.get("errorDistribution") or {}).items() if k != "aborted due to deadline"}
    s = d.get("summary") or {}
    lat = d.get("latencyPercentiles") or {}
    ok = sum(n for c, n in codes.items() if str(c).startswith("2"))
    return {
        "ok": ok,
        "non2xx": sum(codes.values()) - ok,
        "errors": sum(errors.values()),
        "error_kinds": errors,
        "ok_per_s": ok / s["total"] if s.get("total") else 0,
        "p50_ms": (lat.get("p50") or 0) * 1000,
        "p99_ms": (lat.get("p99") or 0) * 1000,
    }


def rates(probe, frac):
    for name in STREAMS:
        r = oha(os.path.join(probe, name + ".json"))
        if not r or r["ok_per_s"] <= 0:
            sys.exit(f"probe: stream {name} served nothing")
        print(name, max(1, int(r["ok_per_s"] * frac)))


def slope(points):
    """Least-squares slope, units per second."""
    n = len(points)
    if n < 3:
        return None
    mx = sum(t for t, _ in points) / n
    my = sum(v for _, v in points) / n
    den = sum((t - mx) ** 2 for t, _ in points)
    return sum((t - mx) * (v - my) for t, v in points) / den if den else None


def report(out, settle=60):
    with open(os.path.join(out, "samples.csv")) as f:
        rows = [{k: float(v) for k, v in r.items() if v} for r in csv.DictReader(f)]
    rows = [r for r in rows if "rss_kb" in r]
    events = {}
    with open(os.path.join(out, "events.csv")) as f:
        for line in f:
            t, name = line.strip().split(",", 1)
            events[name] = float(t)
    t0 = events["start"]

    def window(a, b):
        return [r for r in rows if a <= r["t"] <= b]

    def mb(kb):
        return kb / 1024

    res = {"phases": [], "idle": []}
    md = [f"# Soak: {os.path.basename(out)}", ""]
    idle0 = window(t0, events.get("phase1-start", t0))
    if idle0:
        res["idle"].append({"when": "before", "rss_mb": mb(idle0[-1]["rss_kb"])})
    md += [f"| phase | CPU (charged) | RSS start → end (MB) | RSS max | slope, after the first {settle // 60:g} min | anon slope | requests ok | errors |",
           "|---|---|---|---|---|---|---|---|"]
    p = 1
    while f"phase{p}-start" in events:
        a, b = events[f"phase{p}-start"], events[f"phase{p}-end"]
        w = window(a, b)
        steady = [r for r in w if r["t"] >= a + settle]
        s_rss = slope([(r["t"], r["rss_kb"]) for r in steady])
        s_anon = slope([(r["t"], r["anon"] / 1024) for r in steady])
        cpu = (w[-1]["cpu_usec"] - w[0]["cpu_usec"]) / 1e6 / (w[-1]["t"] - w[0]["t"]) if len(w) > 1 else 0
        streams = {n: oha(os.path.join(out, f"phase{p}", n + ".json")) for n in STREAMS}
        ok = sum(s["ok"] for s in streams.values() if s)
        err = sum(s["errors"] + s["non2xx"] for s in streams.values() if s)
        ph = {"phase": p, "seconds": b - a, "cpu": cpu, "rss_start_mb": mb(w[0]["rss_kb"]), "rss_end_mb": mb(w[-1]["rss_kb"]),
              "rss_max_mb": mb(max(r["rss_kb"] for r in w)), "rss_slope_kb_per_min": s_rss * 60 if s_rss is not None else None,
              "anon_slope_kb_per_min": s_anon * 60 if s_anon is not None else None, "ok": ok, "errors": err, "streams": streams}
        res["phases"].append(ph)
        fmt = lambda v: "n/a" if v is None else f"{v:+.1f} KB/min ({v * 60 / 1024:+.2f} MB/h)"
        md.append(f"| {p} | {cpu:.2f} | {ph['rss_start_mb']:.1f} → {ph['rss_end_mb']:.1f} | {ph['rss_max_mb']:.1f} | "
                  f"{fmt(ph['rss_slope_kb_per_min'])} | {fmt(ph['anon_slope_kb_per_min'])} | {ok:,} | {err:,} |")
        nxt = events.get(f"phase{p + 1}-start", events.get("sigterm"))
        idle = window(b, nxt) if nxt else []
        if idle:
            res["idle"].append({"when": f"after phase {p}", "rss_mb": mb(idle[-1]["rss_kb"])})
        p += 1
    md += ["", "Idle RSS (the last sample of each idle stretch): " +
           ", ".join(f"{i['when']} {i['rss_mb']:.1f} MB" for i in res["idle"])]
    # RSS over time: the mean of each 10-minute stretch of each phase.
    md += ["", "| phase | minutes | RSS mean (MB) | RSS max (MB) | anon mean (MB) |", "|---|---|---|---|---|"]
    for ph in range(1, p):
        a, b = events[f"phase{ph}-start"], events[f"phase{ph}-end"]
        m = 0
        while a + m * 60 < b - 60:
            w = window(a + m * 60, min(b, a + (m + 10) * 60))
            if w:
                md.append(f"| {ph} | {m}–{min(m + 10, (b - a) / 60):.0f} | {mb(sum(r['rss_kb'] for r in w) / len(w)):.1f} | "
                          f"{mb(max(r['rss_kb'] for r in w)):.1f} | {sum(r['anon'] for r in w) / len(w) / 2**20:.1f} |")
            m += 10
    md += ["", "| stream | phase | ok/s | p50 ms | p99 ms | errors |", "|---|---|---|---|---|---|"]
    for ph in res["phases"]:
        for n, s in ph["streams"].items():
            if s:
                kinds = "; ".join(f"{k}: {v}" for k, v in s["error_kinds"].items())
                md.append(f"| {n} | {ph['phase']} | {s['ok_per_s']:.0f} | {s['p50_ms']:.2f} | {s['p99_ms']:.2f} | "
                          f"{s['errors'] + s['non2xx']}{' (' + kinds + ')' if kinds else ''} |")
    # The allocator's report at exit.
    log = open(os.path.join(out, "server.log"), errors="replace").read() if os.path.exists(os.path.join(out, "server.log")) else ""
    leaks = re.findall(r"(?im)^.*leak.*$", log)
    res["leak_lines"] = leaks[:50]
    res["leak_count"] = len([l for l in leaks if re.search(r"(?i)leaked|memory address", l)])
    try:
        res["exit_code"] = open(os.path.join(out, "exit-code")).read().strip()
    except OSError:
        res["exit_code"] = None
    res["stopped_cleanly"] = "server stopped cleanly" in log
    md += ["", f"Exit after SIGTERM: code {res['exit_code']}, "
           f"{'logged \"server stopped cleanly\"' if res['stopped_cleanly'] else 'no clean-stop line'}; "
           f"allocator leak lines: {res['leak_count']}."]
    if leaks:
        md += ["", "```"] + leaks[:20] + ["```"]
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(res, f, indent=1)
    print("\n".join(md))


if __name__ == "__main__":
    if sys.argv[1] == "rates":
        rates(sys.argv[2], float(sys.argv[3]))
    else:
        report(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 60)
