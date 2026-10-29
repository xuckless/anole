#!/usr/bin/env python3
"""Results of bench/repro/ws85.sh.

  ws85-summary.py one <run dir>                one run, one line
  ws85-summary.py profile <profile dir> <run dir>   perf counts per message, flame graph
  ws85-summary.py fair <run dir>               a fairness hold (fair85.sh), one line
  ws85-summary.py table <results dir>          medians per phase, backend and side (Markdown)
"""
import glob, gzip, html, json, os, re, statistics, sys

GOOD = {"video_ok": 0.99, "audio_ok": 0.99, "lat_video_p95_ms": 200}  # as videocall/report.py


def load(p):
    try:
        return [json.loads(l) for l in open(p) if l.strip()]
    except FileNotFoundError:
        return []


def good_users(steps):
    """Users served at good quality, counted as videocall/report.py does."""
    good = 0
    for s in steps:
        ok = s.get("in_call") and (s.get("video_ok") or 0) >= GOOD["video_ok"] and (s.get("audio_ok") or 0) >= GOOD["audio_ok"] \
            and (s.get("lat_video_p95_ms") or 1e9) <= GOOD["lat_video_p95_ms"]
        if ok:
            good = max(good, s.get("connected") or 0)
        elif s["users"] > 4:
            break
    return good


def msgs(row, side):
    return sum(row.get(f"{k}_{side}") or 0 for k in ("video", "audio", "chat"))


def run(d):
    steps = load(os.path.join(d, "steps.jsonl"))
    summ = json.load(open(os.path.join(d, "summary.json"))) if os.path.exists(os.path.join(d, "summary.json")) else {}
    container = open(os.path.join(d, "container.json")).read().strip() if os.path.exists(os.path.join(d, "container.json")) else ""
    r = {"stop": summ.get("stop", "?"), "reached": summ.get("users", 0), "mem_peak_mb": summ.get("mem_peak_mb"),
         "good": good_users(steps), "container": container}
    if "/fixed-" in d and summ.get("stop") == "max users" and len(steps) >= 2:
        h, prev = steps[-1], steps[-2]
        dur = h["t_s"] - prev["t_s"]
        relayed = msgs(h, "recv")
        r.update({
            "hold_s": round(dur, 1), "users": h["users"], "in_call": h["in_call"],
            "cpu_cores": h["cpu"], "relayed_per_s": relayed / dur,
            "cpu_us_per_msg": h["cpu"] * dur / relayed * 1e6 if relayed else None,
            "video_ok": h["video_ok"], "audio_ok": h["audio_ok"],
            "video_p50_ms": h["lat_video_p50_ms"], "video_p99_ms": h["lat_video_p99_ms"],
            "audio_p99_ms": h["lat_audio_p99_ms"], "mem_mb": h["mem_mb"], "errors": h["errors"],
        })
    return r


def one(d):
    r = run(d)
    if "cpu_us_per_msg" in r:
        return (f"{r['users']} users held {r['hold_s']} s: {r['cpu_us_per_msg']:.2f} µs CPU/msg "
                f"({r['cpu_cores']:.3f} cores, {r['relayed_per_s']:,.0f} msg/s), video p50/p99 "
                f"{r['video_p50_ms']:.1f}/{r['video_p99_ms']:.1f} ms, audio p99 {r['audio_p99_ms']:.1f} ms, "
                f"video ok {100 * r['video_ok']:.2f}%, mem {r['mem_mb']:.0f} MB, errors {r['errors']} {r['container']}")
    return (f"good {r['good']} users, reached {r['reached']} ({r['stop']}), "
            f"peak mem {r['mem_peak_mb'] or 0:.0f} MB {r['container']}")


def fold(script_gz):
    """perf script -g output -> {folded stack: samples}."""
    stacks, frames = {}, []

    def flush():
        if frames:
            key = ";".join([frames[0]] + frames[:0:-1])  # comm at the root, then outermost to leaf
            stacks[key] = stacks.get(key, 0) + 1
        frames.clear()

    with gzip.open(script_gz, "rt", errors="replace") as f:
        for line in f:
            if not line.strip():
                flush()
            elif line[0] in " \t":
                parts = line.strip().split(None, 1)
                if len(parts) == 2:
                    sym = re.sub(r"\+0x[0-9a-f]+$", "", parts[1].split(" (")[0])
                    frames.append(sym if sym != "[unknown]" else "?")
            else:
                flush()
                frames.append(line.split()[0])  # the thread's comm, as the root
        flush()
    return stacks


def svg(stacks, title, path, width=1600, row=16):
    """A plain flame graph (widths by samples; colour by name)."""
    root = {"n": 0, "c": {}}
    for st, n in stacks.items():
        node = root
        node["n"] += n
        for fr in st.split(";"):
            node = node["c"].setdefault(fr, {"n": 0, "c": {}})
            node["n"] += n
    total = root["n"] or 1
    rects, depth_max = [], [0]

    def walk(node, x, depth):
        for name, ch in sorted(node["c"].items()):
            w = ch["n"] / total * width
            if w >= 0.3:
                rects.append((x, depth, w, name, ch["n"]))
                depth_max[0] = max(depth_max[0], depth)
                walk(ch, x, depth + 1)
            x += w

    walk(root, 0, 0)
    h = (depth_max[0] + 3) * row
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{h}" font-family="monospace" font-size="11">',
           f'<rect width="100%" height="100%" fill="#fff"/><text x="4" y="13">{html.escape(title)} ({total} samples)</text>']
    for x, d, w, name, n in rects:
        y = h - (d + 1) * row
        hue = (sum(map(ord, name)) * 7) % 60
        label = html.escape(name[: int(w / 7)]) if w > 21 else ""
        out.append(f'<g><title>{html.escape(name)} ({n} samples, {100 * n / total:.2f}%)</title>'
                   f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{row - 1}" fill="hsl({hue},80%,62%)"/>'
                   f'<text x="{x + 2:.1f}" y="{y + 11}">{label}</text></g>')
    out.append("</svg>")
    open(path, "w").write("\n".join(out))


def profile(pd, rd):
    counts = {}
    t = open(os.path.join(pd, "perf-stat.txt")).read()
    for m in re.finditer(r"^\s*([\d,.]+)\s+(?:msec\s+)?(?:syscalls:sys_enter_)?(\S+)", t, re.M):
        try:
            counts[m.group(2)] = float(m.group(1).replace(",", ""))
        except ValueError:
            pass
    t0 = int(open(os.path.join(pd, "stat-start-ns")).read()) / 1e3
    t1 = int(open(os.path.join(pd, "stat-end-ns")).read()) / 1e3
    start = json.load(open(os.path.join(rd, "summary.json")))["start_us"]
    secs = [s for s in load(os.path.join(rd, "seconds.jsonl")) if t0 <= start + s["t_s"] * 1e6 <= t1]
    inbound = sum(msgs(s, "sent") for s in secs)
    relayed = sum(msgs(s, "recv") for s in secs)
    res = {"seconds": len(secs), "inbound_msgs": inbound, "relayed_msgs": relayed}
    reads = sum(counts.get(k, 0) for k in ("read", "readv", "recvfrom", "recvmsg"))
    writes = sum(counts.get(k, 0) for k in ("write", "writev", "sendto", "sendmsg"))
    waits = sum(counts.get(k, 0) for k in ("epoll_wait", "epoll_pwait", "epoll_pwait2", "ppoll", "io_uring_enter"))
    if inbound:
        res.update({"reads_per_inbound_msg": reads / inbound, "writes_per_relayed_msg": writes / max(1, relayed),
                    "waits_per_inbound_msg": waits / inbound,
                    "cpu_us_per_msg_stat": counts.get("task-clock", 0) * 1e3 / max(1, relayed) * len(secs) / 20})
    res["syscalls"] = {k: int(v) for k, v in counts.items() if k != "task-clock"}
    json.dump(res, open(os.path.join(pd, "per-msg.json"), "w"), indent=1)
    sg = os.path.join(pd, "perf-script.txt.gz")
    if os.path.exists(sg):
        st = fold(sg)
        with open(os.path.join(pd, "stacks.folded"), "w") as f:
            for k, v in sorted(st.items()):
                f.write(f"{k} {v}\n")
        svg(st, f"{os.path.basename(pd)}: video-call relay, 600 users, epoll", os.path.join(pd, "flame.svg"))
    return (f"{res.get('reads_per_inbound_msg', 0):.3f} reads/inbound msg, {res.get('writes_per_relayed_msg', 0):.3f} "
            f"writes/relayed msg, {res.get('waits_per_inbound_msg', 0):.3f} waits/inbound msg ({inbound:,} in, {relayed:,} out)")


def pctl(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p / 100))] if xs else 0


def fair_run(d):
    steps = load(os.path.join(d, "steps.jsonl"))
    users = [u for u in load(os.path.join(d, "per_user.jsonl")) if u.get("in_call")]
    held = os.path.exists(os.path.join(d, "vcload.log")) and "holding" in open(os.path.join(d, "vcload.log")).read()
    if len(steps) < 2 or not users or not held:
        return None
    h, prev = steps[-1], steps[-2]
    dur = h["t_s"] - prev["t_s"]
    want = 30 * dur  # 30 fps from each receiver's peer
    vr = [u["video_recv"] for u in users]
    shown = [u["video_shown"] / want for u in users]
    lat = [u["max_lat_ms"] for u in users]
    relayed = msgs(h, "recv")
    r = {"users": h["users"], "in_call": len(users), "hold_s": round(dur, 1),
         "recv_min": min(vr) / want, "recv_p10": pctl(vr, 10) / want, "recv_med": pctl(vr, 50) / want, "recv_max": max(vr) / want,
         "served": sum(x >= 0.9 for x in shown) / len(users), "starved": sum(x < 0.1 for x in shown) / len(users),
         "maxlat_med_ms": pctl(lat, 50), "maxlat_max_ms": max(lat),
         "video_ok": h["video_ok"], "audio_ok": h["audio_ok"],
         "audio_p50_ms": h["lat_audio_p50_ms"], "audio_p99_ms": h["lat_audio_p99_ms"],
         "video_p50_ms": h["lat_video_p50_ms"], "video_p99_ms": h["lat_video_p99_ms"],
         "cpu_cores": h["cpu"], "cpu_us_per_msg": h["cpu"] * dur / relayed * 1e6 if relayed else None, "rss_mb": h["mem_mb"]}
    if os.path.exists(os.path.join(d, "perf-stat.txt")):
        counts = {}
        for m in re.finditer(r"^\s*([\d,.]+)\s+(?:msec\s+)?(?:syscalls:sys_enter_)?(\S+)", open(os.path.join(d, "perf-stat.txt")).read(), re.M):
            try:
                counts[m.group(2)] = float(m.group(1).replace(",", ""))
            except ValueError:
                pass
        t0 = int(open(os.path.join(d, "stat-start-ns")).read()) / 1e3
        t1 = int(open(os.path.join(d, "stat-end-ns")).read()) / 1e3
        start = json.load(open(os.path.join(d, "summary.json")))["start_us"]
        secs = [x for x in load(os.path.join(d, "seconds.jsonl")) if t0 <= start + x["t_s"] * 1e6 <= t1]
        inbound, out_ = sum(msgs(x, "sent") for x in secs), sum(msgs(x, "recv") for x in secs)
        if inbound:
            r["reads_per_in"] = sum(counts.get(k, 0) for k in ("read", "readv", "recvfrom", "recvmsg")) / inbound
            r["writes_per_relayed"] = sum(counts.get(k, 0) for k in ("write", "writev", "sendto", "sendmsg")) / max(1, out_)
            r["waits_per_in"] = sum(counts.get(k, 0) for k in ("epoll_wait", "epoll_pwait", "epoll_pwait2", "ppoll", "io_uring_enter")) / inbound
    return r


def flame(d):
    """Flame graph and the memcpy share of a profile run."""
    sg = os.path.join(d, "perf-script.txt.gz")
    if not os.path.exists(sg):
        return "no perf script"
    st = fold(sg)
    with open(os.path.join(d, "stacks.folded"), "w") as f:
        for k, v in sorted(st.items()):
            f.write(f"{k} {v}\n")
    side = os.path.basename(d)[:-3]
    svg(st, f"{side}: video-call relay, 950 users held, epoll", os.path.join(d, "flame.svg"))
    total = sum(st.values()) or 1
    leaf = lambda k: k.rsplit(";", 1)[-1]
    mem = sum(v for k, v in st.items() if re.search(r"memcpy|memmove", leaf(k)))
    ssl = sum(v for k, v in st.items() if re.search(r"SSL_|aes|gcm|EVP_|tls", k, re.I))
    top = sorted(((v, leaf(k)) for k, v in st.items()), reverse=True)
    agg = {}
    for v, name in top:
        agg[name] = agg.get(name, 0) + v
    top5 = ", ".join(f"{n} {100 * v / total:.1f}%" for n, v in sorted(agg.items(), key=lambda x: -x[1])[:5])
    json.dump({"samples": total, "memcpy_share": mem / total, "ssl_share": ssl / total, "top_self": sorted(agg.items(), key=lambda x: -x[1])[:25]},
              open(os.path.join(d, "flame.json"), "w"), indent=1)
    return f"{total} samples, memcpy/memmove self {100 * mem / total:.1f}%, in TLS stacks {100 * ssl / total:.1f}%; top self: {top5}"


def fair(d):
    r = fair_run(d)
    if not r:
        return "no hold (the run ended before it): not usable"
    sc = f", {r['reads_per_in']:.2f} reads/in, {r['writes_per_relayed']:.2f} writes/relayed" if "reads_per_in" in r else ""
    return (f"{r['in_call']} in call, held {r['hold_s']} s: served {100 * r['served']:.0f}%, starved {100 * r['starved']:.0f}%, "
            f"video recv per receiver min/p10/med/max {r['recv_min']:.2f}/{r['recv_p10']:.2f}/{r['recv_med']:.2f}/{r['recv_max']:.2f}, "
            f"worst latency med/max {r['maxlat_med_ms']:.0f}/{r['maxlat_max_ms']:.0f} ms, audio p50/p99 {r['audio_p50_ms']:.1f}/{r['audio_p99_ms']:.1f} ms, "
            f"video ok {100 * r['video_ok']:.1f}%, {r['cpu_us_per_msg'] or 0:.2f} µs/msg, RSS {r['rss_mb']:.0f} MB{sc}")


def table(out):
    runs = {}
    for d in sorted(glob.glob(os.path.join(out, "*-*-r*", "videocall", "*-ws"))):
        phase, be, rr = os.path.basename(os.path.dirname(os.path.dirname(d))).split("-")
        side = os.path.basename(d)[:-3]
        runs.setdefault((phase, be, side), []).append((rr, run(d)))
    med = lambda xs: statistics.median(xs) if xs else float("nan")
    lines = ["## Ramp to failure (users at good quality; medians of the runs)", "",
             "| backend | side | good users (runs) | median | reached | peak MB |", "|---|---|---|---|---|---|"]
    for (phase, be, side), rs in sorted(runs.items()):
        if phase != "ramp":
            continue
        g = [r["good"] for _, r in sorted(rs)]
        lines.append(f"| {be} | {side} | {' / '.join(map(str, g))} | **{med(g):.0f}** | "
                     f"{med([r['reached'] for _, r in rs]):.0f} | {med([r['mem_peak_mb'] or 0 for _, r in rs]):.0f} |")
    lines += ["", "## Fixed load (held users; medians of the runs)", "",
              "| backend | side | CPU µs/msg (runs) | median | cores | msg/s | video p50 / p99 ms | audio p99 ms | video ok | RSS MB |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    for (phase, be, side), rs in sorted(runs.items()):
        if phase != "fixed":
            continue
        rs = [r for _, r in sorted(rs) if "cpu_us_per_msg" in r]
        if not rs:
            continue
        c = [r["cpu_us_per_msg"] for r in rs]
        lines.append(f"| {be} | {side} | {' / '.join(f'{x:.2f}' for x in c)} | **{med(c):.2f}** | {med([r['cpu_cores'] for r in rs]):.3f} | "
                     f"{med([r['relayed_per_s'] for r in rs]):,.0f} | {med([r['video_p50_ms'] for r in rs]):.1f} / {med([r['video_p99_ms'] for r in rs]):.1f} | "
                     f"{med([r['audio_p99_ms'] for r in rs]):.1f} | {100 * med([r['video_ok'] for r in rs]):.2f}% | {med([r['mem_mb'] for r in rs]):.0f} |")
    prof = sorted(glob.glob(os.path.join(out, "profile", "*", "per-msg.json")))
    if prof:
        lines += ["", "## Profile runs (epoll, one each, 20 s of perf stat inside a 600-user hold)", "",
                  "| side | reads / inbound msg | writes / relayed msg | waits / inbound msg | syscalls |", "|---|---|---|---|---|"]
        for p in prof:
            j = json.load(open(p))
            sc = ", ".join(f"{k} {v:,}" for k, v in j["syscalls"].items() if v)
            lines.append(f"| {os.path.basename(os.path.dirname(p))} | {j.get('reads_per_inbound_msg', 0):.3f} | "
                         f"{j.get('writes_per_relayed_msg', 0):.3f} | {j.get('waits_per_inbound_msg', 0):.3f} | {sc} |")
    fr = sorted(glob.glob(os.path.join(out, "fair-*", "videocall", "*-ws")))
    if fr:
        lines += ["", "## Fairness holds (950 users joined fast, settled 30 s, held 60 s; one run each)", "",
                  "Per receiver: video received as a share of the 30 fps its peer sent. Served: ≥ 90% shown; starved: < 10%.", "",
                  "| backend | side | served | starved | recv min / p10 / med / max | worst lat med / max ms | audio p50 / p99 ms | video ok | µs/msg | RSS MB | reads/in | writes/relayed |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for d in fr:
            r = fair_run(d)
            if not r:
                continue
            be = os.path.basename(os.path.dirname(os.path.dirname(d)))[5:]
            lines.append(f"| {be} | {os.path.basename(d)[:-3]} | {100 * r['served']:.0f}% | {100 * r['starved']:.0f}% | "
                         f"{r['recv_min']:.2f} / {r['recv_p10']:.2f} / {r['recv_med']:.2f} / {r['recv_max']:.2f} | "
                         f"{r['maxlat_med_ms']:.0f} / {r['maxlat_max_ms']:.0f} | {r['audio_p50_ms']:.1f} / {r['audio_p99_ms']:.1f} | "
                         f"{100 * r['video_ok']:.1f}% | {r['cpu_us_per_msg'] or 0:.2f} | {r['rss_mb']:.0f} | "
                         f"{r.get('reads_per_in', 0):.2f} | {r.get('writes_per_relayed', 0):.2f} |")
    print("\n".join(lines))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "one":
        print(one(sys.argv[2]))
    elif mode == "flame":
        print(flame(sys.argv[2]))
    elif mode == "fair":
        print(fair(sys.argv[2]))
    elif mode == "profile":
        print(profile(sys.argv[2], sys.argv[3]))
    else:
        table(sys.argv[2])
