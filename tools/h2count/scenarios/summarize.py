#!/usr/bin/env python3
"""Per-scenario peak table (markdown) from h2count JSON reports: summarize.py a.json b.json ..."""
import json, sys

COLS = [("conns", None), ("streams", "peak_streams"), ("req/s", "requests/s"), ("PING/s", "ping/s"), ("PING tot", "ping/conn_total"),
        ("SETT frames", "settings/conn_total"), ("ent/frame", "settings_entries_per_frame"), ("RST/s", "rst/s"), ("RST/100ms", "rst/100ms"),
        ("RST unans.", "rst_unanswered/conn_total"), ("empty DATA", "data_empty/conn_total"), ("empty HDR", "headers_empty/conn_total"),
        ("empty CONT", "continuation_empty/conn_total"), ("unknown", "unknown/conn_total"), ("CONT/blk", "continuations_per_block"),
        ("hdr blk B", "header_block_bytes"), ("WU/s", "window_update/s"), ("PRIO/s", "priority/s"), ("PRIO tot", "priority/conn_total")]
# Rows that are not evidence of what a real client does: tools that drive the protocol by hand.
SYNTHETIC = ("ping-tool-driven", "h2load-synthetic", "raw-continuation", "header-200k")
MAXIMA = [("PING/s", "ping/s"), ("PING/100ms", "ping/100ms"), ("SETTINGS frames per connection", "settings/conn_total"),
          ("SETTINGS entries per frame", "settings_entries_per_frame"), ("RST_STREAM/s", "rst/s"), ("RST_STREAM/100ms", "rst/100ms"),
          ("unanswered RST_STREAM/s", "rst_unanswered/s"), ("empty DATA total", "data_empty/conn_total"), ("empty HEADERS total", "headers_empty/conn_total"),
          ("empty CONTINUATION total", "continuation_empty/conn_total"), ("unknown frames total", "unknown/conn_total"),
          ("CONTINUATION per block", "continuations_per_block"), ("header block bytes", "header_block_bytes"), ("WINDOW_UPDATE/s", "window_update/s"),
          ("PRIORITY/s", "priority/s"), ("PRIORITY/100ms", "priority/100ms"), ("peak concurrent streams", "peak_streams"), ("requests/s", "requests/s")]
rows = []
print("| scenario | " + " | ".join(c for c, _ in COLS) + " |")
print("|---|" + "---|" * len(COLS))
for path in sys.argv[1:]:
    for s in json.load(open(path))["scenarios"]:
        if s["name"] == "start":
            continue
        r = s["rollup_max_over_connections"]
        rows.append((s["name"], r))
        print(f"| {s['name']} | " + " | ".join(str(s["connections"] if k is None else r.get(k, 0)) for _, k in COLS) + " |")

print()
print("| highest legitimate value (synthetic rows excluded) | value | scenario |")
print("|---|---|---|")
for label, key in MAXIMA:
    best = max(((r.get(key, 0), n) for n, r in rows if not any(x in n for x in SYNTHETIC)), default=(0, ""))
    print(f"| {label} | {best[0]} | {best[1]} |")
