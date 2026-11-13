#!/usr/bin/env python3
"""Per-scenario peak table (markdown) from h2count JSON reports: summarize.py a.json b.json ..."""
import json, sys

COLS = [("conns", None), ("streams", "peak_streams"), ("req/s", "requests/s"), ("PING/s", "ping/s"), ("PING tot", "ping/conn_total"),
        ("SETT frames", "settings/conn_total"), ("ent/frame", "settings_entries_per_frame"), ("RST/s", "rst/s"), ("RST/100ms", "rst/100ms"),
        ("RST unans.", "rst_unanswered/conn_total"), ("empty DATA", "data_empty/conn_total"), ("empty HDR", "headers_empty/conn_total"),
        ("empty CONT", "continuation_empty/conn_total"), ("unknown", "unknown/conn_total"), ("CONT/blk", "continuations_per_block"),
        ("hdr blk B", "header_block_bytes"), ("WU/s", "window_update/s"), ("PRIO/s", "priority/s"), ("PRIO tot", "priority/conn_total"),
        ("PRIO_UPD/s", "priority_update/s"), ("PRIO_UPD tot", "priority_update/conn_total")]
# Rows that are not evidence of what a real client does: tools that drive the protocol by hand.
SYNTHETIC = ("ping-tool-driven", "h2load-synthetic", "raw-continuation", "header-200k", "raw-priority")
MAXIMA = [("PING/s", "ping/s"), ("PING/100ms", "ping/100ms"), ("SETTINGS frames per connection", "settings/conn_total"),
          ("SETTINGS entries per frame", "settings_entries_per_frame"), ("RST_STREAM/s", "rst/s"), ("RST_STREAM/100ms", "rst/100ms"),
          ("unanswered RST_STREAM/s", "rst_unanswered/s"), ("empty DATA total", "data_empty/conn_total"), ("empty HEADERS total", "headers_empty/conn_total"),
          ("empty CONTINUATION total", "continuation_empty/conn_total"), ("unknown frames total", "unknown/conn_total"),
          ("CONTINUATION per block", "continuations_per_block"), ("header block bytes", "header_block_bytes"), ("WINDOW_UPDATE/s", "window_update/s"),
          ("PRIORITY/s", "priority/s"), ("PRIORITY/100ms", "priority/100ms"),
          ("PRIORITY_UPDATE/s", "priority_update/s"), ("PRIORITY_UPDATE/100ms", "priority_update/100ms"), ("peak concurrent streams", "peak_streams"), ("requests/s", "requests/s")]
rows = []
codes = {}      # (scenario, "s2c_goaway:0xb") -> count, over all connections
server_settings = {}
debug = []      # (scenario, GOAWAY debug data the server sent)
print("| scenario | " + " | ".join(c for c, _ in COLS) + " |")
print("|---|" + "---|" * len(COLS))
for path in sys.argv[1:]:
    for s in json.load(open(path))["scenarios"]:
        if s["name"] == "start":
            continue
        r = s["rollup_max_over_connections"]
        rows.append((s["name"], r))
        for c in s.get("conns", []):
            for k, v in (c.get("error_codes") or {}).items():
                codes[(s["name"], k)] = codes.get((s["name"], k), 0) + v
            for d in c.get("s2c_goaway_debug") or []:
                debug.append((s["name"], d))
            for k, v in (c.get("server_settings") or {}).items():
                server_settings[k] = server_settings.get(k, 0) + v
        print(f"| {s['name']} | " + " | ".join(str(s["connections"] if k is None else r.get(k, 0)) for _, k in COLS) + " |")

print()
print("| highest legitimate value (synthetic rows excluded) | value | scenario |")
print("|---|---|---|")
for label, key in MAXIMA:
    best = max(((r.get(key, 0), n) for n, r in rows if not any(x in n for x in SYNTHETIC)), default=(0, ""))
    print(f"| {label} | {best[0]} | {best[1]} |")

# Server-sent GOAWAY and RST_STREAM error codes: GOAWAY with a code other than 0 (NO_ERROR) is a connection the
# server closed on purpose (0xb = ENHANCE_YOUR_CALM is a flood budget); RST codes 0x0 and 0x8 (CANCEL) are normal.
print()
print("| scenario | server frame:code | count |")
print("|---|---|---|")
for (n, k), v in sorted(codes.items()):
    if k.startswith("s2c_"):
        print(f"| {n} | {k} | {v} |")
# Client-sent GOAWAY with a code other than NO_ERROR (a browser closing a session with live streams says INTERNAL_ERROR).
print()
print("| scenario | client GOAWAY code | count |")
print("|---|---|---|")
for (n, k), v in sorted(codes.items()):
    if k.startswith("c2s_goaway:") and k != "c2s_goaway:0x0":
        print(f"| {n} | {k[len('c2s_goaway:'):]} | {v} |")
for n, d in debug:
    print(f"\nGOAWAY debug data in {n}: `{d}`")
print()
print("| server SETTINGS entry (id=value) | frames |")
print("|---|---|")
for k, v in sorted(server_settings.items()):
    print(f"| {k} | {v} |")

# Headroom: engine default (limits.zig and config.zig; keep these values in step with them) over the highest legitimate observed value; below 2.5x is flagged.
# Rates a budget does not charge (PRIORITY, PRIORITY_UPDATE) are listed with their limit as "exempt".
LIMITS = [("empty DATA/HEADERS/CONT per second", 100, "data_empty/s"), ("SETTINGS entries per frame", 32, "settings_entries_per_frame"),
          ("CONTINUATION per block", 8, "continuations_per_block"), ("peak concurrent streams", 250, "peak_streams"),
          ("header block bytes", 65536, "header_block_bytes"), ("unanswered RST_STREAM in 1 s (bucket burst 1000; the 33/s refill is not observable here)", 1000, "rst_unanswered/s")]
print()
print("| budget | limit | highest legitimate | headroom |")
print("|---|---|---|---|")
for label, lim, key in LIMITS:
    best = max((r.get(key, 0) for n, r in rows if not any(x in n for x in SYNTHETIC)), default=0)
    h = "no observation" if best == 0 else f"{lim / best:.1f}x" + ("  FLAG < 2.5x" if lim / best < 2.5 else "")
    print(f"| {label} | {lim} | {best} | {h} |")
for label, key in (("PRIORITY/s", "priority/s"), ("PRIORITY_UPDATE/s", "priority_update/s")):
    best = max((r.get(key, 0) for n, r in rows if not any(x in n for x in SYNTHETIC)), default=0)
    print(f"| {label} (glitch rate 330/s) | exempt | {best} | not charged |")
