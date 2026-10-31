#!/usr/bin/env python3
"""Summaries and flame graphs for bench/atlas/atlas.sh.

  atlas-summary.py one <cell dir>      one cell: flames (cpu, offcpu, mem-alloc,
                                       mem-held), summary.json, one log line
  atlas-summary.py table <atlas dir>   summary.md and index.json over every cell
"""
import gzip, importlib.util, json, os, re, statistics, sys
from collections import Counter, defaultdict

_spec = importlib.util.spec_from_file_location("ws85", os.path.join(os.path.dirname(__file__), "..", "repro", "ws85-summary.py"))
ws = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ws)
svg = ws.svg

# Self time by component: the leaf frame's name (kernel frames end in _[k]).
KERNEL = [
    ("kernel netfilter", r"^(nf_|nft_|ipt_|ip6t_|__nf_|nf_conntrack|nf_hook|conntrack)"),
    ("kernel io_uring", r"^(io_|__io_|io_uring)"),
    ("kernel file I/O", r"^(filemap_|vfs_|generic_file|ext4_|btrfs_|xfs_|overlay|ovl_|page_cache|do_sys_open|path_|link_path|do_filp_open|__x64_sys_(openat|pread64|read|statx|newfstatat|close))"),
    ("kernel memory", r"(page_fault|_page|pages|folio|clear_page|memcg|mmap|munmap|brk|vma|lru|zap_|tlb|__memset|memset_orig)"),
    ("kernel copy", r"(copy_user|copy_to|copy_from|memcpy|memmove|csum)"),
    ("kernel net", r"^(tcp_|__tcp|ip_|__ip|ipv4|ipv6|udp|__udp|skb|__skb|kfree_skb|consume_skb|__dev|dev_|netif|__netif|napi|__napi|net_|sock|__sock|sk_|__sk|inet|loopback|__x64_sys_(sendto|recvfrom|sendmsg|recvmsg|writev|readv|read|write)|do_softirq|handle_softirqs|__local_bh|process_backlog|tcp|release_sock|lock_sock|__release_sock)"),
    ("kernel sched/epoll", r"(schedule|switch|pick_|enqueue|dequeue|update_curr|ttwu|try_to_wake|wake_up|futex|ep_|epoll|hrtimer|tick_|irq|cpuidle|idle)"),
    ("kernel syscall entry", r"(entry_SYSCALL|syscall|do_syscall|__x64_sys|fdget|fput|__fget|security_|selinux|avc_|audit)"),
]
USER = [
    ("memcpy/memset", r"(?i)(memcpy|memmove|memset|compiler_rt\.mem|compiler_rt\.fastMem|bcmp)"),
    ("malloc (libc)", r"^(_int_malloc|_int_free|malloc|free|cfree|calloc|realloc|_int_realloc|malloc_consolidate|tcache|unlink_chunk|__libc_malloc|__libc_free|__libc_calloc|__libc_realloc|_int_free_merge_chunk|_int_free_create_chunk|_int_free_chunk|_int_free_maybe_consolidate|sysmalloc|systrim|arena_get2)"),
    ("zig heap", r"^heap\."),
    ("BoringSSL", r"(^bssl|^_ZN4bssl|^_ZL|^SSL_|^ssl_|^tls1?3?_|^EVP_|^CRYPTO_|^OPENSSL_|^BN_|^bn_|^ec_|^EC_|^x25519|^aes|^gcm|^GCM|^ChaCha|^chacha|^poly1305|^CRYPTO|^sha|^SHA|^HMAC|^hkdf|^HKDF|^BIO_|^ERR_|^ecp_nistz|^RAND_|^rand_|^fiat_|^OPENSSL|^boringssl|^X509|^x509|^ASN1|^asn1|^CBB_|^CBS_|^cbb_|^cbs_|^d2i|^i2d)"),
    ("nghttp2", r"^nghttp2_"),
    ("ngtcp2", r"^ngtcp2_"),
    ("nghttp3", r"^(nghttp3_|sfparse)"),
    ("compression", r"(CreateBackwardReferences|StoreSymbol|build_tree|send_tree|init_block|HIST_count|deflate|inflate|zng_|crc32|adler32|longest_match|compress_block|fill_window|Brotli|brotli|ZSTD_|HUF_|FSE_|zstd|lz4|LZ4|slide_hash|update_hash|insert_string|chunkcopy|emit_|quick_|gzip)"),
    ("json", r"(json\.|Stringify|stringify|yyjson)"),
    ("zio runtime", r"^(runtime\.|coro\.|task\.|ev\.|common\.|io\.|group\.|blocking|completion|sync\.|select\.|channel\.|Io\.|time\.|timer|stack_pool|switchContext|zio)"),
    ("grpc", r"(grpc|protobuf|pb\.)"),
    ("h2 glue", r"^(h2\.|http2|server\.h2|.*\.h2\.|.*H2)"),
    ("h3/quic glue", r"^(h3\.|quic\.|.*\.h3\.|.*\.quic\.|.*Quic|.*H3|endpoint\.)"),
    ("tls glue", r"(^tls\.|\.tls\.|Tls)"),
    ("anole http/net", r"^(llhttp|server\.|http\.|dusty|parser\.|response\.|request\.|router\.|route|static|handler|middleware|net\.|console|metrics|block_cache|main\.|features\.|arena\.|Server|Request|Response|Router|headers|url|uri|mime|date|fmt\.)"),
]
KERNEL_RE = [(n, re.compile(p)) for n, p in KERNEL]
USER_RE = [(n, re.compile(p)) for n, p in USER]


def component_of(stack):
    """A sample's component: its leaf's, except that kernel work under a
    netfilter hook counts as netfilter, and an unnamed user leaf (a library's
    static function, '?') takes its nearest named ancestor's."""
    fr = stack.split(";")[1:]
    leaf = fr[-1] if fr else "?"
    c = component(leaf)
    if leaf.endswith("_[k]"):
        if c != "kernel netfilter" and any(f.startswith(("nft_", "nf_hook", "nf_conntrack", "ipt_")) for f in fr):
            return "kernel netfilter"
        return c
    if c in ("other user", "unknown"):
        for f in reversed(fr[:-1]):
            a = component(f)
            if a not in ("other user", "unknown") and not a.startswith("kernel"):
                return a
    return c


def component(frame):
    if frame.endswith("_[k]"):
        f = frame[:-4]
        for n, r in KERNEL_RE:
            if r.search(f):
                return n
        return "kernel other"
    for n, r in USER_RE:
        if r.search(frame):
            return n
    if frame in ("?", "[unknown]"):
        return "unknown"
    return "other user"


def fold_perf(path):
    """perf script -g (gzip) -> {folded: samples}; root = thread name, kernel frames marked _[k]."""
    stacks, frames = Counter(), []
    root = [None]

    def flush():
        if root[0] is not None and frames:
            stacks[";".join([root[0]] + frames[::-1])] += 1
        frames.clear()
        root[0] = None

    with gzip.open(path, "rt", errors="replace") as f:
        for line in f:
            if not line.strip():
                flush()
            elif line[0] in " \t":
                parts = line.strip().split(None, 1)
                if len(parts) == 2:
                    sym, _, dso = parts[1].partition(" (")
                    sym = re.sub(r"\+0x[0-9a-f]+$", "", sym)
                    if sym == "[unknown]":
                        sym = "?"
                    if dso.startswith("[") and not dso.startswith("[unknown"):  # [kernel.kallsyms], [nf_tables], ...
                        sym += "_[k]"
                    frames.append(sym)
            else:
                flush()
                root[0] = re.sub(r"\d+$", "", line.split()[0]) or line.split()[0]
        flush()
    return stacks


def fold_offcpu(path):
    st = Counter()
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        if not line or " " not in line:
            continue
        k, _, v = line.rpartition(" ")
        try:
            st[k] += int(v)
        except ValueError:
            pass
    return st


def parse_bpftrace(path):
    """bpftrace map dump -> {map: [(key or stack frames, value)]}."""
    op = gzip.open if path.endswith(".gz") else open
    maps, lines = defaultdict(list), op(path, "rt", errors="replace").read().split("\n")
    i = 0
    frame_re = re.compile(r"^\s+([0-9a-f]+)\s+(.*?)(?:\+\d+)?\s+\((.*)\)$")
    while i < len(lines):
        m = re.match(r"^@(\w+)\[(.*)$", lines[i])
        if not m:
            i += 1
            continue
        name, rest = m.groups()
        one_line = re.match(r"^(.*)\]: (.*)$", rest)
        if rest and one_line and not rest.endswith("]: "):
            maps[name].append((one_line.group(1), one_line.group(2)))
            i += 1
            continue
        if rest == "":  # a stack key: frames, then "]: value"
            frames, i = [], i + 1
            while i < len(lines) and not lines[i].startswith("]: "):
                fm = frame_re.match(lines[i])
                if fm:
                    frames.append(fm.group(2))
                i += 1
            val = lines[i][3:] if i < len(lines) else "0"
            maps[name].append((frames, val))
            i += 1
            continue
        # a scalar key with a stack value: "@lst[ptr]: " then frames, then a blank line
        key = rest[: rest.rfind("]")]
        frames, i = [], i + 1
        while i < len(lines) and lines[i].strip():
            fm = frame_re.match(lines[i])
            if fm:
                frames.append(fm.group(2))
            i += 1
        maps[name].append((key, frames))
    return maps


def clean(frames):
    out = [re.sub(r"\+\d+$", "", f) for f in frames if f not in ("0", "[unknown]")]
    return out[::-1] or ["?"]


def mem(d):
    p = os.path.join(d, "mem.txt")
    if not os.path.exists(p):
        p += ".gz"
    if not os.path.exists(p):
        return None, {}, {}
    maps = parse_bpftrace(p)
    alloc, held, res = Counter(), Counter(), {}
    for name, entries in maps.items():
        if name.startswith(("a_", "c_")):
            kind, probe = name.split("_", 1)
            tot = 0
            for frames, v in entries:
                try:
                    v = int(v)
                except ValueError:
                    continue
                tot += v
                if kind == "a":
                    alloc[";".join([probe] + clean(frames))] += v
            res.setdefault(probe, {})["bytes" if kind == "a" else "calls"] = tot
    sizes = {k: int(v) for k, v in maps.get("live", []) if str(v).isdigit()}
    for k, frames in maps.get("lst", []):
        if k in sizes and isinstance(frames, list):
            held[";".join(["malloc held"] + clean(frames))] += sizes[k]
    res["held"] = {"bytes": sum(sizes.values()), "blocks": len(sizes)}
    return res, alloc, held


def perf_csv(path):
    c = {}
    if not os.path.exists(path):
        return c, False
    ok = True
    for line in open(path):
        f = line.strip().split(",")
        if len(f) < 6 or line.startswith("#"):
            continue
        name = f[2].split("/")[1] if "/" in f[2] else f[2]
        try:
            c[name] = float(f[0])
        except ValueError:
            ok = False
            continue
        try:
            if float(f[5] or f[4]) < 99.99:
                ok = False
        except (ValueError, IndexError):
            pass
    return c, ok


def count_info(d):
    t = open(os.path.join(d, "count.txt"), errors="replace").read() if os.path.exists(os.path.join(d, "count.txt")) else ""
    n, ok, rps = None, False, None
    m = re.search(r"requests: (\d+) total, \d+ started, (\d+) done, (\d+) succeeded, (\d+) failed, (\d+) errored, (\d+) timeout", t)
    s = re.search(r"status codes: (\d+) 2xx", t)
    r = re.search(r"finished in [\d.]+m?s, ([\d.]+) req/s", t)
    if m:
        n = int(m.group(3))
        ok = int(m.group(1)) == n and m.group(4) == m.group(5) == m.group(6) == "0" and s and int(s.group(1)) == n
    if r:
        rps = float(r.group(1))
    if not m:  # tcpload's JSON
        try:
            j = json.loads(t[t.index("{"):])
            n, rps, ok = j["messages"], j["msgs_per_s"], j.get("errors", 0) == 0
        except (ValueError, KeyError):
            pass
    return n, ok, rps


def top_self(stacks, k=5):
    tot = sum(stacks.values()) or 1
    leaf = Counter()
    for st, v in stacks.items():
        leaf[st.rsplit(";", 1)[-1]] += v
    return [(f, 100 * v / tot) for f, v in leaf.most_common(k)]


def components(stacks):
    tot = sum(stacks.values()) or 1
    c = Counter()
    for st, v in stacks.items():
        c[component_of(st)] += v
    return {k: 100 * v / tot for k, v in c.most_common()}


def threads(stacks):
    tot = sum(stacks.values()) or 1
    c = Counter()
    for st, v in stacks.items():
        c[st.split(";", 1)[0]] += v
    return {k: 100 * v / tot for k, v in c.most_common(6)}


def rss(d):
    p = os.path.join(d, "rss.tsv")
    rows = []
    if os.path.exists(p):
        for line in open(p):
            f = line.split()
            if len(f) >= 3 and f[1].isdigit():
                rows.append((float(f[0]), int(f[1]), int(f[2]) if f[2].isdigit() else 0, int(f[3]) if len(f) > 3 and f[3].isdigit() else 0))
    if not rows:
        return {}
    t0 = rows[0][0]
    return {"t": [round(r[0] - t0, 1) for r in rows], "cgroup_mb": [round(r[1] / 2**20, 1) for r in rows],
            "rss_mb": [round(r[2] / 1024, 1) for r in rows], "threads": [r[3] for r in rows],
            "peak_cgroup_mb": round(max(r[1] for r in rows) / 2**20, 1), "peak_rss_mb": round(max(r[2] for r in rows) / 1024, 1),
            "start_rss_mb": round(rows[0][2] / 1024, 1), "end_rss_mb": round(rows[-1][2] / 1024, 1),
            # What stays after the peak (the SSE cells: subscribers held, the connection ramp's buffers gone).
            "settled_rss_mb": round(min(r[2] for r in rows[max(range(len(rows)), key=lambda i: rows[i][2]):]) / 1024, 1)}


def one(d):
    be, cell = d.rstrip("/").split("/")[-2:]
    title = f"{cell} ({be}, 1 executor)"
    s = {"cell": cell, "backend": be}
    s["backend_fds"] = open(os.path.join(d, "backend")).read().split() if os.path.exists(os.path.join(d, "backend")) else []
    s["state"] = open(os.path.join(d, "state")).read().strip() if os.path.exists(os.path.join(d, "state")) else "?"
    n, ok, rps = count_info(d)
    c, full = perf_csv(os.path.join(d, "count.perf.csv"))
    if n:
        s["count"] = {"n": n, "valid": bool(ok and full and c), "max_rps": rps}
        for k, name in (("instructions", None), ("cycles", None), ("page-faults", None), ("context-switches", None)):
            pass
        if c:
            # The two instruction events share a name; perf writes them in EV's order.
            vals = [l.strip().split(",") for l in open(os.path.join(d, "count.perf.csv")) if l.count(",") >= 4 and not l.startswith("#")]
            v = [float(x[0]) if x[0].replace(".", "").isdigit() else None for x in vals]
            if len(v) >= 5 and None not in v[:5]:
                iu, cu, ik, pf, cs = v[:5]
                s["count"].update({"instr_u_req": iu / n, "cycles_u_req": cu / n, "instr_k_req": ik / n,
                                   "ipc_u": iu / cu if cu else 0, "pf_req": pf / n, "cs_req": cs / n})
    out = {}
    pp = os.path.join(d, "perf-script.txt.gz")
    if os.path.exists(pp):
        st = fold_perf(pp)
        svg(st, f"CPU: {title}", os.path.join(d, "cpu.svg"))
        with gzip.open(os.path.join(d, "cpu.folded.gz"), "wt") as f:
            f.writelines(f"{k} {v}\n" for k, v in st.most_common())
        tot = sum(st.values()) or 1
        k = sum(v for kk, v in st.items() if kk.rsplit(";", 1)[-1].endswith("_[k]"))
        s["cpu"] = {"samples": tot, "kernel_pct": 100 * k / tot, "top_self": top_self(st), "components": components(st), "threads": threads(st)}
        out["cpu"] = "cpu.svg"
    po = os.path.join(d, "offcpu.folded")
    if os.path.exists(po) and os.path.getsize(po):
        st = fold_offcpu(po)
        svg(st, f"Off-CPU (µs): {title}", os.path.join(d, "offcpu.svg"))
        tot = sum(st.values()) or 1
        def why(k):  # the thread, its last user frames and the syscall it waits in
            f = k.split(";")
            e = next((i for i, x in enumerate(f) if x.startswith("entry_SYSCALL")), len(f))
            sc = next((x for x in f[e:] if x.startswith("__x64_sys_")), f[-1])
            return f"{f[0]}: {';'.join(f[max(1, e - 2):e])} -> {sc}"
        why_t = Counter()
        for k, v in st.items():
            why_t[why(k)] += v
        s["offcpu"] = {"total_ms": tot / 1000, "threads": threads(st),
                       "top": [(k, 100 * v / tot) for k, v in why_t.most_common(5)]}
        out["offcpu"] = "offcpu.svg"
    res, alloc, held = mem(d)
    if res is not None:
        mr = open(os.path.join(d, "mem-rps")).read().strip() if os.path.exists(os.path.join(d, "mem-rps")) else ""
        reqs = int(mr) * 10 if mr.isdigit() else None
        if not reqs and os.path.exists(os.path.join(d, "load-mem.txt")):  # tcpload: its rate over the 10 s window
            try:
                t = open(os.path.join(d, "load-mem.txt")).read()
                reqs = int(json.loads(t[t.index("{"):])["msgs_per_s"] * 10)
            except (ValueError, KeyError):
                pass
        if cell.startswith("sse"):  # per subscriber, as /publish counted them
            sub = re.search(r"\d+", open(os.path.join(d, "subscribers")).read()) if os.path.exists(os.path.join(d, "subscribers")) else None
            reqs = int(sub.group()) if sub else None
            s["subscribers"] = reqs
        s["mem"] = {"window_requests": reqs, "probes": res,
                    "held_truncated": os.path.exists(os.path.join(d, "mem-map-full"))}  # bpftrace's live map filled up
        if reqs:
            s["mem"]["per_req"] = {p: {k: v / reqs for k, v in r.items()} for p, r in res.items() if p != "held"}
        if alloc:
            svg(alloc, f"Bytes allocated per stack: {title}", os.path.join(d, "mem-alloc.svg"))
            s["mem"]["top_alloc"] = [(";".join(k.split(";")[:1] + k.split(";")[-3:]), v) for k, v in alloc.most_common(6)]
            out["mem_alloc"] = "mem-alloc.svg"
        if held:
            svg(held, f"malloc bytes held at the window's end: {title}", os.path.join(d, "mem-held.svg"))
            s["mem"]["top_held"] = [(";".join(k.split(";")[-3:]), v) for k, v in held.most_common(5)]
            out["mem_held"] = "mem-held.svg"
    s["rss"] = rss(d)
    if os.path.exists(os.path.join(d, "memory.peak")):
        s["rss"]["memory_peak_mb"] = round(int(open(os.path.join(d, "memory.peak")).read()) / 2**20, 1)
    s["flames"] = out
    json.dump(s, open(os.path.join(d, "summary.json"), "w"), indent=1)
    cnt = s.get("count", {})
    line = [f"{s['state']}"]
    if cnt:
        line.append(f"max {cnt.get('max_rps') or 0:,.0f}/s, {cnt.get('instr_u_req', 0):,.0f} ins:u/req, "
                    f"{cnt.get('instr_k_req', 0):,.0f} ins:k/req, {cnt.get('pf_req', 0):.3f} pf/req{'' if cnt.get('valid') else ' INVALID'}")
    if "cpu" in s:
        line.append("top " + ", ".join(f"{f} {p:.1f}%" for f, p in s["cpu"]["top_self"][:3]))
    if s.get("mem", {}).get("per_req"):
        pr = s["mem"]["per_req"]
        line.append("B/req " + ", ".join(f"{p} {r.get('bytes', 0):,.0f}" for p, r in pr.items() if r.get("bytes")))
    line.append(f"peak {s['rss'].get('peak_rss_mb', 0)} MB RSS")
    print(" | ".join(line))


def table(out):
    rows = []
    for be in sorted(os.listdir(out)):
        bd = os.path.join(out, be)
        if not os.path.isdir(bd) or be == "req":
            continue
        for cell in os.listdir(bd):
            p = os.path.join(bd, cell, "summary.json")
            if os.path.exists(p):
                rows.append(json.load(open(p)))
    order = os.environ.get("CELLS", "").split()
    rows.sort(key=lambda r: (order.index(r["cell"]) if r["cell"] in order else 99, r["cell"], r["backend"]))
    L = ["| cell | backend | max req/s | ins:u/req | cyc:u/req | IPC:u | ins:k/req | pf/req | ctx-sw/req | kernel % of CPU | peak RSS MB |",
         "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        c = r.get("count", {})
        f = lambda k, fmt: (fmt.format(c[k]) if k in c else "")
        L.append(f"| {r['cell']} | {r['backend']} | {f('max_rps', '{:,.0f}')} | {f('instr_u_req', '{:,.0f}')}{'' if c.get('valid', True) else ' (invalid)'} | "
                 f"{f('cycles_u_req', '{:,.0f}')} | {f('ipc_u', '{:.2f}')} | {f('instr_k_req', '{:,.0f}')} | {f('pf_req', '{:.3f}')} | {f('cs_req', '{:.3f}')} | "
                 f"{r.get('cpu', {}).get('kernel_pct', 0):.0f} | {r.get('rss', {}).get('peak_rss_mb', '')} |")
    L += ["", "## CPU by component (self time, % of the server's samples at the fixed load)", ""]
    comps = ["kernel net", "kernel netfilter", "kernel io_uring", "kernel file I/O", "kernel sched/epoll", "kernel syscall entry", "kernel memory", "kernel copy", "kernel other",
             "BoringSSL", "nghttp2", "ngtcp2", "nghttp3", "compression", "json", "memcpy/memset", "malloc (libc)", "zig heap", "zio runtime",
             "anole http/net", "h2 glue", "h3/quic glue", "tls glue", "grpc", "other user", "unknown"]
    L.append("| cell | backend | " + " | ".join(comps) + " |")
    L.append("|---|---|" + "---:|" * len(comps))
    for r in rows:
        cp = r.get("cpu", {}).get("components", {})
        L.append(f"| {r['cell']} | {r['backend']} | " + " | ".join(f"{cp[k]:.1f}" if cp.get(k, 0) >= 0.05 else "" for k in comps) + " |")
    L += ["", "## Top-5 self-time symbols", ""]
    for r in rows:
        ts = r.get("cpu", {}).get("top_self", [])
        if ts:
            L.append(f"- **{r['cell']} / {r['backend']}:** " + "; ".join(f"`{f}` {p:.1f}%" for f, p in ts))
    L += ["", "## Memory: bytes allocated per request (low fixed load; sse: per subscriber), calls per request", "",
          "≥: bpftrace's live-allocation map filled (4,096 keys), so the held figure is a lower bound; the allocated bytes are complete.", ""]
    probes = ["malloc", "calloc", "realloc", "arena", "block", "page", "mmap", "brk", "taskpool", "reqbufs", "stackpool"]
    L.append("| cell | backend | " + " | ".join(probes) + " | malloc held at end (KB, blocks) |")
    L.append("|---|---|" + "---:|" * (len(probes) + 1))
    for r in rows:
        m = r.get("mem", {})
        pr = m.get("per_req", {})
        def cellv(p):
            x = pr.get(p, {})
            b, n = x.get("bytes"), x.get("calls")
            if not b and not n:
                return ""
            return (f"{b:,.0f} B" if b else "") + (f" / {n:.2f}" if n else "")
        h = m.get("probes", {}).get("held", {})
        L.append(f"| {r['cell']} | {r['backend']} | " + " | ".join(cellv(p) for p in probes) + f" | {'≥ ' if m.get('held_truncated') else ''}{h.get('bytes', 0) / 1024:,.0f}, {h.get('blocks', 0)} |")
    L += ["", "## Off-CPU (top stacks by time, all threads)", ""]
    for r in rows:
        oc = r.get("offcpu", {})
        if oc:
            L.append(f"- **{r['cell']} / {r['backend']}** ({oc['total_ms']:,.0f} ms): " + "; ".join(f"{k} {p:.0f}%" for k, p in oc["top"][:3]))
    open(os.path.join(out, "summary.md"), "w").write("\n".join(L) + "\n")
    json.dump(rows, open(os.path.join(out, "index.json"), "w"), indent=1)
    print("\n".join(L))


if __name__ == "__main__":
    {"one": lambda: one(sys.argv[2]), "table": lambda: table(sys.argv[2])}[sys.argv[1]]()
