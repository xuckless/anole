#!/usr/bin/env python3
"""Summaries for bench/repro/net-ab.sh.

  net-ab-summary.py one  <run dir>    one run, one line
  net-ab-summary.py cell <cell dir>   medians per side, B against A, the gate
  net-ab-summary.py table <results>   Markdown tables of every cell
  net-ab-summary.py flame <prof dir> <title>   flame graph of a net-prof.sh run
"""
import importlib.util, json, os, statistics, sys

GATE = 0.02  # B within 2% of A (messages/s and p99) or better


def run(d):
    j = json.load(open(os.path.join(d, "load.json")))
    rate = j.get("msgs_per_s", j.get("received_per_s", 0.0))
    dur = float(open(os.path.join(d, "dur")).read())
    msgs = rate * dur
    r = {"rate": rate, "p50": j["p50_ms"], "p99": j["p99_ms"],
         "loss": j.get("errors", j.get("lost", 0))}
    cpu = int(open(os.path.join(d, "cpu-usec")).read())
    r["us_msg"] = cpu / msgs if msgs else 0
    try:
        for line in open(os.path.join(d, "perf-stat.csv")):
            f = line.strip().split(",")
            if len(f) < 3 or not f[0].replace(".", "").isdigit():
                continue
            if f[2] == "cpu_core/instructions/u":
                r["ins_msg"] = float(f[0]) / msgs if msgs else 0
            elif f[2] == "cpu_core/cycles/u":
                r["cyc_msg"] = float(f[0]) / msgs if msgs else 0
            elif f[2] == "page-faults":
                r["pf_msg"] = float(f[0]) / msgs if msgs else 0
            elif f[2] == "syscalls:sys_enter_brk":
                r["brk_msg"] = float(f[0]) / msgs if msgs else 0
    except FileNotFoundError:
        pass
    return r


def one(d):
    r = run(d)
    return (f"{r['rate']:.0f} msg/s, p50 {r['p50']:.3f} ms, p99 {r['p99']:.3f} ms, "
            f"{r['us_msg']:.2f} us CPU/msg, {r.get('ins_msg', 0):.0f} ins:u/msg, "
            f"{r.get('cyc_msg', 0):.0f} cyc:u/msg, {r.get('pf_msg', 0):.3f} faults/msg, {r.get('brk_msg', 0):.3f} brk/msg, lost/errors {r['loss']}")


def cell(cd):
    sides = {}
    for e in sorted(os.listdir(cd)):
        s, _, _ = e.partition("-r")
        try:
            sides.setdefault(s, []).append(run(os.path.join(cd, e)))
        except (FileNotFoundError, json.JSONDecodeError, KeyError, ValueError):
            pass
    med = {s: {k: statistics.median(x.get(k, 0) for x in rs) for k in ("rate", "p50", "p99", "us_msg", "ins_msg", "cyc_msg", "pf_msg", "brk_msg")}
           | {"n": len(rs), "loss": sum(x["loss"] for x in rs), "rates": [round(x["rate"]) for x in rs]}
           for s, rs in sides.items()}
    return med


def verdict(med):
    a, b = med.get("a"), med.get("b")
    if not a or not b or not a["rate"]:
        return None
    dr = b["rate"] / a["rate"] - 1
    dp = b["p99"] / a["p99"] - 1 if a["p99"] else 0
    ok = dr >= -GATE and dp <= GATE
    return dr, dp, ok


def cell_line(cd):
    med = cell(cd)
    parts = [f"{s}: {m['rate']:.0f} msg/s, p99 {m['p99']:.3f} ms, {m['us_msg']:.2f} us/msg, "
             f"{m['ins_msg']:.0f} ins/msg, {m['pf_msg']:.3f} faults/msg, {m['brk_msg']:.3f} brk/msg (n={m['n']}, runs {m['rates']}, lost {m['loss']})" for s, m in sorted(med.items())]
    v = verdict(med)
    if v:
        parts.append(f"B vs A: msg/s {v[0]*100:+.1f}%, p99 {v[1]*100:+.1f}% -> {'pass' if v[2] else 'FAIL'}")
    return "; ".join(parts)


def table(root):
    rows = ["| backend | proto | size | conns | A msg/s | B msg/s | Δ msg/s | A p99 ms | B p99 ms | Δ p99 | A µs/msg | B µs/msg | A ins/msg | B ins/msg | A faults/msg | B faults/msg | A brk/msg | B brk/msg | gate |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for be in ("epoll", "uring"):
        bd = os.path.join(root, be)
        if not os.path.isdir(bd):
            continue
        def key(c):
            p, sz, n = c.split("-")
            return (p, int(sz), int(n[1:]))
        for c in sorted(os.listdir(bd), key=key):
            med = cell(os.path.join(bd, c))
            v = verdict(med)
            if not v:
                continue
            a, b = med["a"], med["b"]
            p, sz, n = key(c)
            rows.append(f"| {be} | {p} | {sz} | {n} | {a['rate']:,.0f} | {b['rate']:,.0f} | {v[0]*100:+.1f}% | "
                        f"{a['p99']:.3f} | {b['p99']:.3f} | {v[1]*100:+.1f}% | {a['us_msg']:.2f} | {b['us_msg']:.2f} | "
                        f"{a['ins_msg']:.0f} | {b['ins_msg']:.0f} | {a['pf_msg']:.3f} | {b['pf_msg']:.3f} | {a['brk_msg']:.3f} | {b['brk_msg']:.3f} | "
                        f"{'pass' if v[2] else '**fail**'} |")
    return "\n".join(rows)


def flame(d, title):
    """Folded stacks, flame.svg and the top self symbols (ws85-summary's fold and svg)."""
    spec = importlib.util.spec_from_file_location("ws85", os.path.join(os.path.dirname(__file__), "ws85-summary.py"))
    ws = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ws)
    st = ws.fold(os.path.join(d, "perf-script.txt.gz"))
    with open(os.path.join(d, "stacks.folded"), "w") as f:
        for k, v in sorted(st.items()):
            f.write(f"{k} {v}\n")
    ws.svg(st, title, os.path.join(d, "flame.svg"))
    total = sum(st.values()) or 1
    agg = {}
    for k, v in st.items():
        leaf = k.rsplit(";", 1)[-1]
        agg[leaf] = agg.get(leaf, 0) + v
    top = sorted(agg.items(), key=lambda x: -x[1])[:25]
    json.dump({"samples": total, "top_self": top}, open(os.path.join(d, "flame.json"), "w"), indent=1)
    return f"{total} samples; top self: " + ", ".join(f"{n} {100 * v / total:.1f}%" for n, v in top[:6])


def counters(d):
    """perf stat counters per message (net-prof.sh's counted window)."""
    j = json.load(open(os.path.join(d, "load.json")))
    rate = j.get("msgs_per_s", j.get("received_per_s", 0.0))
    msgs = rate * float(open(os.path.join(d, "stat-seconds")).read())
    out = []
    for line in open(os.path.join(d, "perf-stat.csv")):
        f = line.strip().split(",")
        if len(f) >= 3 and f[0].replace(".", "").isdigit() and not f[2].startswith("cpu_atom"):
            out.append(f"{f[2].replace('cpu_core/', '').replace('syscalls:sys_enter_', '').rstrip('/')} {float(f[0]) / msgs:.3f}/msg")
    return f"{rate:.0f} msg/s; " + ", ".join(out)


if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "flame":
        print(flame(path, sys.argv[3]))
    else:
        print({"one": one, "cell": cell_line, "table": table, "counters": counters}[mode](path))
