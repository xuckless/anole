#!/usr/bin/env python3
"""Builds the video-call results page: OUT/index.html, one file with the data
in it (no server needed).

    report.py bench/results/<id>/videocall

Reads each <app>-<transport>/ directory: steps.jsonl (one row per user
count), quality.jsonl (the probe call's scores), summary.json (why it
stopped) and container.json (exit state).
"""
import json
import os
import sys

GOOD = {"video_ok": 0.99, "audio_ok": 0.99, "lat_video_p95_ms": 200}


def load(path):
    if not os.path.exists(path):
        return []
    return [json.loads(l) for l in open(path) if l.strip()]


def main():
    out = sys.argv[1]
    runs = {}
    for name in sorted(os.listdir(out)):
        d = os.path.join(out, name)
        if not os.path.isdir(d) or "-" not in name:
            continue
        app, transport = name.split("-", 1)
        steps = load(os.path.join(d, "steps.jsonl"))
        q = {r["users"]: r for r in load(os.path.join(d, "quality.jsonl"))}
        rows = []
        for s in steps:
            r = {k: s.get(k) for k in (
                "users", "connected", "in_call", "video_ok", "audio_ok", "chat_ok",
                "lat_video_p50_ms", "lat_video_p95_ms", "lat_video_p99_ms", "lat_audio_p99_ms",
                "lat_chat_p50_ms", "lat_chat_p99_ms", "lat_api_p99_ms", "lat_join_p50_ms",
                "mem_mb", "cpu", "load_cpu", "errors", "disconnects", "connect_errors",
                "mbps_up", "mbps_down", "video_sent")}
            if not s.get("in_call"):
                for k in ("video_ok", "audio_ok", "chat_ok"):
                    r[k] = None
            r["error_rate"] = (s.get("errors") or 0) / max(1, (s.get("video_sent") or 0) + (s.get("audio_sent") or 0))
            r.update({k: v for k, v in q.get(s["users"], {}).items() if k != "users"})
            rows.append(r)
        summary = json.load(open(os.path.join(d, "summary.json"))) if os.path.exists(os.path.join(d, "summary.json")) else {}
        container = json.load(open(os.path.join(d, "container.json"))) if os.path.exists(os.path.join(d, "container.json")) else {}
        good = 0
        for r in rows:
            if (r["video_ok"] or 0) >= GOOD["video_ok"] and (r["audio_ok"] or 0) >= GOOD["audio_ok"] \
                    and (r["lat_video_p95_ms"] or 1e9) <= GOOD["lat_video_p95_ms"]:
                # Users actually served: past its limit a server may stop
                # taking new users while the connected ones still do fine.
                good = max(good, r["connected"] or 0)
            elif r["users"] > 4:
                break
        runs.setdefault(transport, {})[app] = {
            "rows": rows, "stop": summary.get("stop", "not run"), "users": summary.get("users", 0),
            "seconds": summary.get("seconds"), "mem_peak_mb": summary.get("mem_peak_mb"),
            "container": container.get("container", ""), "good_users": good, "clip": summary.get("clip", ""),
            "batch": summary.get("batch", 1),
        }
    data = json.dumps(runs, separators=(",", ":"))
    html = PAGE.replace("/*DATA*/null", data)
    with open(os.path.join(out, "index.html"), "w") as f:
        f.write(html)
    print(f"wrote {os.path.join(out, 'index.html')}")


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Video Call Benchmark</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<style>
:root {
  --bg: #f7f7f5; --panel: #ffffff; --text: #1d1d1b; --muted: #6b6b66; --line: #e3e3de;
  --accent: #0f766e; --bad: #b42318;
  --anole: #0f766e; --bun: #c2410c; --fiber: #2563eb; --axum: #7c3aed;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #141413; --panel: #1e1e1c; --text: #ecece8; --muted: #9a9a93; --line: #33332f;
    --accent: #2dd4bf; --bad: #f87171;
    --anole: #2dd4bf; --bun: #fb923c; --fiber: #60a5fa; --axum: #a78bfa;
  }
}
:root[data-theme="dark"] {
  --bg: #141413; --panel: #1e1e1c; --text: #ecece8; --muted: #9a9a93; --line: #33332f;
  --accent: #2dd4bf; --bad: #f87171;
  --anole: #2dd4bf; --bun: #fb923c; --fiber: #60a5fa; --axum: #a78bfa;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 1180px; margin: 0 auto; padding: 24px 16px 64px; }
h1 { font-size: 26px; margin: 0 0 4px; letter-spacing: -0.01em; }
h2 { font-size: 17px; margin: 32px 0 10px; }
p.lead { color: var(--muted); margin: 0 0 20px; max-width: 760px; }
.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 16px; }
.controls { position: sticky; top: 0; z-index: 5; display: flex; flex-wrap: wrap; gap: 16px; align-items: center;
  background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px 16px; margin-bottom: 16px; }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.seg button { border: 0; background: transparent; color: var(--text); padding: 6px 14px; font: inherit; cursor: pointer; }
.seg button[aria-pressed="true"] { background: var(--accent); color: var(--bg); }
.slider { flex: 1 1 320px; display: flex; gap: 12px; align-items: center; }
.slider input { flex: 1; accent-color: var(--accent); }
.users { font-variant-numeric: tabular-nums; font-weight: 600; min-width: 112px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
.card h3 { margin: 0 0 6px; font-size: 13px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
.card canvas { width: 100%; height: 160px; }
.lines { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 12px; }
.lines canvas { width: 100%; height: 230px; }
table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); }
th { color: var(--muted); font-weight: 600; font-size: 13px; }
.swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; vertical-align: baseline; }
.note { color: var(--muted); font-size: 13px; }
.tablewrap { overflow-x: auto; }
.crash { color: var(--bad); }
</style>
</head>
<body>
<main>
<h1>Video call benchmark</h1>
<p class="lead">1:1 calls on one CPU and 2 GB (no swap). Each user streams 1080p H.264 at 4 Mbit/s and Opus audio to its peer, and chats every 3 s; the server deflates every packet it relays. One user joins every step until the server crashes or calls collapse. Drag the slider to compare the four servers at any number of concurrent users.</p>

<div class="controls">
  <div class="seg" id="transport"></div>
  <label class="slider"><span class="users" id="userLabel"></span>
    <input type="range" id="users" min="1" value="10" aria-label="concurrent users"></label>
</div>

<h2>At this many users</h2>
<div class="grid" id="bars"></div>

<h2>Whole ramp</h2>
<div class="lines" id="lines"></div>

<h2>Summary</h2>
<div class="panel tablewrap"><table id="summary"></table>
<p class="note">Good quality: at least 99% of video frames shown and 99% of audio packets played on time, with video p95 one-way latency at most 200 ms. "Shown" means arrived within 200 ms and every frame since its keyframe did too. VMAF and PSNR are for the probe call (users 0 and 1), rebuilt frame by frame from what arrived.</p>
<p class="note">CPU: the container is charged for its own work and its system calls, but not for the kernel's network interrupt work on its core. At saturation that is 10&ndash;25% of the core, so a full core shows as 0.73&ndash;0.88 here. Users are added 10 at a time every 5 s.</p></div>
</main>
<script>
const DATA = /*DATA*/null;
const APPS = ["anole", "bun", "fiber", "axum"];
const METRICS = [
  { key: "video_ok", label: "Video frames shown", unit: "%", scale: 100, max: 100 },
  { key: "audio_ok", label: "Audio played on time", unit: "%", scale: 100, max: 100 },
  { key: "lat_video_p95_ms", label: "Video latency p95", unit: "ms", log: true },
  { key: "lat_video_p50_ms", label: "Video latency p50", unit: "ms", log: true },
  { key: "lat_chat_p99_ms", label: "Chat latency p99", unit: "ms", log: true },
  { key: "probe_vmaf", label: "VMAF (probe call)", unit: "", max: 100 },
  { key: "probe_video_psnr_db", label: "PSNR (probe call)", unit: "dB", max: 60 },
  { key: "probe_audio_snr_db", label: "Audio SNR (probe call)", unit: "dB", max: 60 },
  { key: "mem_mb", label: "Server memory", unit: "MB" },
  { key: "cpu", label: "Server CPU charged to the container", unit: "cores", max: 1.05 },
  { key: "error_rate", label: "Error rate", unit: "%", scale: 100 },
  { key: "in_call", label: "Users in a call", unit: "" },
];
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const color = a => css("--" + a);
const ORDER = ["ws", "ws-h2", "ws-h3", "wt"];
const TRANSPORTS = Object.keys(DATA).sort((a, b) => ORDER.indexOf(a) - ORDER.indexOf(b));
let transport = TRANSPORTS[0] || "ws";
let users = 10;
const charts = [];

function runs() { return DATA[transport] || {}; }
function apps() { return APPS.filter(a => runs()[a]); }
function rowAt(app, n) { return (runs()[app].rows || []).find(r => r.users === n); }
function maxUsers() { return Math.max(1, ...apps().map(a => runs()[a].users || 0)); }
function val(m, r) { if (!r || r[m.key] == null) return null; return r[m.key] * (m.scale || 1); }

function buildControls() {
  const seg = document.getElementById("transport");
  seg.innerHTML = "";
  for (const t of TRANSPORTS) {
    const b = document.createElement("button");
    b.textContent = { ws: "WebSocket", "ws-h2": "WebSocket over HTTP/2", "ws-h3": "WebSocket over HTTP/3", wt: "WebTransport" }[t] || t;
    b.setAttribute("aria-pressed", t === transport);
    b.onclick = () => { transport = t; build(); };
    seg.appendChild(b);
  }
  const s = document.getElementById("users");
  // Runs that add 10 users a step have rows every 10 users; the slider
  // moves in 10s then, and single-step runs are read at the same counts.
  const step = Math.max(1, ...apps().map(a => runs()[a].batch || 1));
  s.step = step;
  s.min = step;
  s.max = maxUsers();
  users = Math.max(step, Math.round(Math.min(users, maxUsers()) / step) * step);
  s.value = users;
  s.oninput = () => { users = +s.value; update(); };
}

function build() {
  charts.splice(0).forEach(c => c.destroy());
  buildControls();
  Chart.defaults.color = css("--muted");
  Chart.defaults.borderColor = css("--line");
  Chart.defaults.font.family = getComputedStyle(document.body).fontFamily;
  const bars = document.getElementById("bars"), lines = document.getElementById("lines");
  bars.innerHTML = ""; lines.innerHTML = "";
  for (const m of METRICS) {
    const card = document.createElement("div");
    card.className = "panel card";
    card.innerHTML = `<h3>${m.label}${m.unit ? " (" + m.unit + ")" : ""}</h3><canvas></canvas>`;
    bars.appendChild(card);
    const bar = new Chart(card.querySelector("canvas"), {
      type: "bar",
      data: { labels: apps(), datasets: [{ data: [], backgroundColor: apps().map(color), borderRadius: 4 }] },
      options: { animation: { duration: 200 }, maintainAspectRatio: false, plugins: { legend: { display: false },
        tooltip: { callbacks: { label: c => c.raw == null ? "not running" : fmt(c.raw, m) } } },
        scales: { y: { beginAtZero: true, suggestedMax: m.max } } },
    });
    bar.$metric = m; bar.$kind = "bar"; charts.push(bar);

    const lc = document.createElement("div");
    lc.className = "panel card";
    lc.innerHTML = `<h3>${m.label}${m.unit ? " (" + m.unit + ")" : ""} vs users</h3><canvas></canvas>`;
    lines.appendChild(lc);
    const line = new Chart(lc.querySelector("canvas"), {
      type: "line",
      data: { datasets: apps().map(a => ({ label: a, borderColor: color(a), backgroundColor: color(a),
        pointRadius: 0, borderWidth: 1.6, tension: 0.15,
        data: runs()[a].rows.map(r => ({ x: r.users, y: val(m, r) })) })) },
      options: { animation: false, maintainAspectRatio: false, parsing: false, interaction: { mode: "nearest", intersect: false },
        plugins: { legend: { labels: { boxWidth: 10 } }, tooltip: { callbacks: { label: c => `${c.dataset.label}: ${fmt(c.raw.y, m)}` } } },
        scales: { x: { type: "linear", min: 1, max: maxUsers(), title: { display: true, text: "concurrent users" } },
          y: { type: m.log ? "logarithmic" : "linear", beginAtZero: !m.log, suggestedMax: m.max } } },
      plugins: [{ id: "marker", afterDraw(c) { const x = c.scales.x.getPixelForValue(users), a = c.chartArea;
        const ctx = c.ctx; ctx.save(); ctx.strokeStyle = css("--text"); ctx.globalAlpha = .35; ctx.setLineDash([4, 4]);
        ctx.beginPath(); ctx.moveTo(x, a.top); ctx.lineTo(x, a.bottom); ctx.stroke(); ctx.restore(); } }],
    });
    line.$kind = "line"; charts.push(line);
  }
  summary();
  update();
}

function fmt(v, m) {
  if (v == null) return "–";
  const d = Math.abs(v) >= 100 ? 0 : Math.abs(v) >= 10 ? 1 : 2;
  return v.toFixed(d) + (m.unit && m.unit !== "cores" ? (m.unit === "%" ? "%" : " " + m.unit) : m.unit === "cores" ? " cores" : "");
}

function update() {
  document.getElementById("userLabel").textContent = users + (users === 1 ? " user" : " users");
  for (const c of charts) {
    if (c.$kind === "bar") {
      c.data.datasets[0].data = apps().map(a => val(c.$metric, rowAt(a, users)));
      c.update();
    } else c.draw();
  }
}

function summary() {
  const t = document.getElementById("summary");
  let h = "<tr><th>server</th><th>users with good quality</th><th>users reached</th><th>how it ended</th><th>peak memory</th><th>container</th></tr>";
  for (const a of apps()) {
    const r = runs()[a];
    const crashed = /crash/.test(r.stop);
    h += `<tr><td><span class="swatch" style="background:${color(a)}"></span>${a}</td><td><b>${r.good_users}</b></td>` +
      `<td>${r.users}</td><td class="${crashed ? "crash" : ""}">${r.stop}</td><td>${r.mem_peak_mb ? r.mem_peak_mb.toFixed(0) + " MB" : "–"}</td><td class="note">${r.container}</td></tr>`;
  }
  t.innerHTML = h;
}

if (window.matchMedia) matchMedia("(prefers-color-scheme: dark)").addEventListener("change", build);
build();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
