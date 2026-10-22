#!/usr/bin/env python3
"""Scores the probe call of one video-call run (vcload's probe.csv).

    quality.py RUN_DIR MEDIA_DIR

Users 0 and 1 form the first call and stay in it for the whole ramp. For
each of them as a receiver, this rebuilds what their screen and speaker
would have played, step by step:

  video  a frame shows when it arrived within the playout deadline and every
         frame since its keyframe showed too; otherwise the screen holds the
         last frame shown (a freeze). Each slot is compared with the frame
         that should have been on screen: PSNR (luma, global MSE per step) and
         VMAF (Netflix's vmaf, on the steps that had any freeze; a step with
         none plays the clip exactly, the "intact" score).
  audio  a 20 ms packet plays when it arrived within its deadline; a lost or
         late one is silence. SNR of the played signal against the clip.

Writes RUN_DIR/quality.jsonl: one line per user count, both receivers
averaged. The decoded reference (yuv, ~5.6 GB) is made in MEDIA_DIR/.work
and deleted at the end.
"""
import csv
import json
import os
import subprocess
import sys
import tempfile
import threading
from collections import defaultdict

import numpy as np

W, H = 1920, 1080
FRAME = W * H * 3 // 2
Y = W * H


def load_probe(path):
    frames = defaultdict(dict)  # receiver -> kind -> {seq: (sent, recv, ok)}
    starts = defaultdict(list)  # (sender, kind) -> [(seq, pos)]
    with open(path) as f:
        for row in csv.DictReader(f):
            if row["ok"] == "start":
                starts[(int(row["receiver"]), int(row["kind"]))].append((int(row["seq"]), int(row["key"])))
                continue
            r, k = int(row["receiver"]), int(row["kind"])
            frames[r].setdefault(k, {})[int(row["seq"])] = (int(row["sent_us"]), int(row["recv_us"]), row["ok"] == "true", row["key"] == "1")
    return frames, starts


def clip_index(starts, seq, n):
    """The clip position of a sender's frame `seq`."""
    best = None
    for s, pos in starts:
        if s <= seq and (best is None or s > best[0]):
            best = (s, pos)
    if best is None:
        return None
    return (best[1] + seq - best[0]) % n


def step_bounds(run):
    """[(users, t_end_us)] from steps.jsonl, as absolute times."""
    rows = [json.loads(l) for l in open(os.path.join(run, "steps.jsonl")) if l.strip()]
    return rows


def main():
    run, media = sys.argv[1], sys.argv[2]
    summary = json.load(open(os.path.join(run, "summary.json")))
    vdl = summary["video_deadline_ms"] * 1000
    adl = summary["audio_deadline_ms"] * 1000
    frames, starts = load_probe(os.path.join(run, "probe.csv"))
    steps = step_bounds(run)
    if not steps or not frames:
        print("no probe data")
        return
    work = os.path.join(media, ".work")
    os.makedirs(work, exist_ok=True)
    ref = os.path.join(work, "ref.yuv")
    if not os.path.exists(ref):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", os.path.join(media, "video.h264"),
                        "-f", "rawvideo", "-pix_fmt", "yuv420p", ref], check=True)
    yuv = np.memmap(ref, dtype=np.uint8, mode="r")
    nframes = yuv.size // FRAME
    pcm_path = os.path.join(work, "ref.pcm")
    if not os.path.exists(pcm_path):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", os.path.join(media, "audio.opus"),
                        "-f", "s16le", "-ac", "1", "-ar", "48000", pcm_path], check=True)
    pcm = np.fromfile(pcm_path, dtype=np.int16).astype(np.float64)
    per_pkt = 960
    npkts = len(pcm) // per_pkt

    def luma(i):
        return yuv[i * FRAME: i * FRAME + Y]

    mse_cache = {}

    def mse(a, b):
        if a == b:
            return 0.0
        key = (min(a, b), max(a, b))
        if key not in mse_cache:
            d = luma(a).astype(np.int32) - luma(b).astype(np.int32)
            mse_cache[key] = float(np.mean(d * d))
        return mse_cache[key]

    # Step i covers sends from the previous step's end to its own (t_s is
    # seconds since vcload started, start_us).
    start_us = summary["start_us"]
    ends = [(s["users"], start_us + int(s["t_s"] * 1e6)) for s in steps]

    def step_of(t):
        for users, end in ends:
            if t <= end:
                return users
        return None

    out = defaultdict(lambda: defaultdict(float))
    vmaf_jobs = defaultdict(list)  # users -> [(receiver, [(shown, want)])]
    for r in (0, 1):
        sender = 1 - r
        vid = frames.get(r, {}).get(1, {})
        vstarts = starts.get((sender, 1), [])
        if not vid or not vstarts:
            continue
        broken, last_shown = True, None
        slots = defaultdict(list)
        for seq in range(min(vid), max(vid) + 1):
            want = clip_index(vstarts, seq, nframes)
            if want is None:
                continue
            got = vid.get(seq)
            if got is None:
                broken, show = True, False
                sent = None
            else:
                sent, recv, ok, key = got
                on_time = ok and recv - sent <= vdl
                if key and on_time:
                    broken = False
                elif not on_time:
                    broken = True
                show = on_time and not broken
            if show:
                last_shown = want
            if sent is None:
                continue
            users = step_of(sent)
            if users is None:
                continue
            shown = last_shown if last_shown is not None else -1
            slots[users].append((shown, want))
        for users, sl in slots.items():
            ms = [mse(s, w) if s >= 0 else 255.0 ** 2 for s, w in sl]
            o = out[users]
            o["video_slots"] += len(sl)
            o["video_frozen"] += sum(1 for s, w in sl if s != w)
            o["mse_sum"] += sum(ms)
            if any(s != w for s, w in sl):
                vmaf_jobs[users].append(sl)

        aud = frames.get(r, {}).get(2, {})
        astarts = starts.get((sender, 2), [])
        if aud and astarts:
            sig = defaultdict(lambda: [0.0, 0.0, 0, 0])
            for seq in range(min(aud), max(aud) + 1):
                p = clip_index(astarts, seq, npkts)
                got = aud.get(seq)
                if got is None:
                    continue
                sent, recv, ok, _ = got
                users = step_of(sent)
                if users is None:
                    continue
                refseg = pcm[p * per_pkt:(p + 1) * per_pkt]
                played = ok and recv - sent <= adl
                e = float(np.sum(refseg * refseg))
                sig[users][0] += e
                sig[users][1] += 0.0 if played else e
                sig[users][2] += 1
                sig[users][3] += 0 if played else 1
            for users, (e, n, cnt, lost) in sig.items():
                o = out[users]
                o["audio_energy"] += e
                o["audio_noise"] += n
                o["audio_pkts"] += cnt
                o["audio_lost"] += lost

    intact = vmaf_score([(i, i) for i in range(0, min(nframes, 150))], yuv, work)
    rows = []
    for users in sorted(out):
        o = out[users]
        mean_mse = o["mse_sum"] / max(1, o["video_slots"])
        psnr = 60.0 if mean_mse == 0 else min(60.0, 10 * np.log10(255.0 ** 2 / mean_mse))
        if vmaf_jobs.get(users):
            pairs = [p for sl in vmaf_jobs[users] for p in sl]
            vm = vmaf_score(pairs, yuv, work)
        else:
            vm = intact
        snr = 60.0 if o["audio_noise"] == 0 else min(60.0, 10 * np.log10(o["audio_energy"] / o["audio_noise"]))
        rows.append({"users": users, "probe_video_psnr_db": round(psnr, 2), "probe_vmaf": round(vm, 2),
                     "probe_video_frozen": round(o["video_frozen"] / max(1, o["video_slots"]), 4),
                     "probe_audio_snr_db": round(snr, 2),
                     "probe_audio_lost": round(o["audio_lost"] / max(1, o["audio_pkts"]), 4)})
    with open(os.path.join(run, "quality.jsonl"), "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    print(f"{run}: {len(rows)} steps scored (intact VMAF {intact:.2f})")


def vmaf_score(pairs, yuv, work):
    """Mean VMAF of the shown frames against the wanted ones (subsampled)."""
    pairs = pairs[::3]  # every third slot: VMAF at 1080p is slow
    if not pairs:
        return 0.0
    with tempfile.TemporaryDirectory(dir=work) as d:
        ref_p, dis_p, log = os.path.join(d, "ref.y4m"), os.path.join(d, "dis.y4m"), os.path.join(d, "out.json")
        os.mkfifo(ref_p)
        os.mkfifo(dis_p)
        hdr = f"YUV4MPEG2 W{W} H{H} F30:1 Ip A1:1 C420jpeg\n".encode()
        black = np.zeros(FRAME, dtype=np.uint8)
        black[Y:] = 128

        def write(path, idx):
            with open(path, "wb") as f:
                f.write(hdr)
                for i in idx:
                    f.write(b"FRAME\n")
                    f.write((black if i < 0 else yuv[i * FRAME:(i + 1) * FRAME]).tobytes())

        proc = subprocess.Popen(["vmaf", "-r", ref_p, "-d", dis_p, "--threads", str(os.cpu_count() or 4),
                                 "--json", "-o", log, "-q"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tr = threading.Thread(target=write, args=(ref_p, [w for _, w in pairs]))
        td = threading.Thread(target=write, args=(dis_p, [s for s, _ in pairs]))
        tr.start()
        td.start()
        tr.join()
        td.join()
        proc.wait()
        try:
            return float(json.load(open(log))["pooled_metrics"]["vmaf"]["mean"])
        except (OSError, KeyError, ValueError):
            return 0.0


if __name__ == "__main__":
    main()
