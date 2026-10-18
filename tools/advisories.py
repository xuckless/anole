#!/usr/bin/env python3
"""Known vulnerabilities in the C libraries Anole bundles, at the pinned versions.

    tools/advisories.py [path/to/build.zig.zon]

Versioned upstreams are checked against their GitHub security advisories,
BoringSSL (pinned by commit, no releases) against OSV. Exits 1 when a pin is
affected, 2 when a pin moved and the table below needs updating. Set
GH_TOKEN (or GITHUB_TOKEN) to avoid GitHub's anonymous rate limit.
"""
import json
import os
import re
import sys
import urllib.request

# name: (advisory repo, version, pattern that must match the pin in
# build.zig.zon). nghttp2 comes from the xuckless fork: v1.70.0 plus the
# RFC 9113 strictness patch; ngtcp2 too: v1.25.0 plus the migration patch;
# nghttp3 too: v1.18.0 plus nghttp3_conn_add_extra_setting.
VERSIONED = {
    "nghttp2": ("nghttp2/nghttp2", "1.70.0", r"xuckless/nghttp2/archive/0f8bc1c4271f4380409071eade31830e6e436bd6"),
    "ngtcp2": ("ngtcp2/ngtcp2", "1.25.0", r"xuckless/ngtcp2/archive/591e959bc67820226651ee8f009a265899bfc71c"),
    "nghttp3": ("ngtcp2/nghttp3", "1.18.0", r"xuckless/nghttp3/archive/de4bcb905eca28cdfe0e6ef4280b355e1c29660d"),
    "zlib-ng": ("zlib-ng/zlib-ng", "2.3.3", r"zlib-ng/archive/refs/tags/2\.3\.3\.tar"),
    "zstd": ("facebook/zstd", "1.5.7", r"zstd/archive/refs/tags/v1\.5\.7\.tar"),
    "yyjson": ("ibireme/yyjson", "0.13.0", r"yyjson/archive/refs/tags/0\.13\.0\.tar"),
    "hiredis": ("redis/hiredis", "1.5.0", r"hiredis/archive/refs/tags/v1\.5\.0\.tar"),
}
BORINGSSL = re.compile(r"google/boringssl/archive/([0-9a-f]{40})\.tar")


def fetch(url, body=None):
    headers = {"Accept": "application/json", "User-Agent": "anole-advisories"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    if data:
        headers["Content-Type"] = "application/json"
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=30) as r:
        return json.load(r)


def version(text):
    parts = re.findall(r"\d+", text.strip().lstrip("vV"))
    return tuple(int(p) for p in parts[:4]) or None


def in_range(v, spec):
    """GitHub's vulnerable_version_range: comma-separated constraints such as
    "< 1.2.3", ">= 1.0, <= 1.4", "= 1.9.0", or a bare version."""
    for c in spec.split(","):
        c = c.strip()
        m = re.match(r"(<=|>=|<|>|=)?\s*(.+)", c)
        if not m:
            return False
        op, ref = m.group(1) or "=", version(m.group(2))
        if ref is None:
            return False
        ok = {"<": v < ref, "<=": v <= ref, ">": v > ref, ">=": v >= ref, "=": v == ref}[op]
        if not ok:
            return False
    return True


def main():
    zon_path = sys.argv[1] if len(sys.argv) > 1 else "build.zig.zon"
    zon = open(zon_path).read()
    affected = []
    stale = []
    for name, (repo, pinned, pattern) in VERSIONED.items():
        if not re.search(pattern, zon):
            stale.append(name)
            continue
        v = version(pinned)
        advisories = fetch(f"https://api.github.com/repos/{repo}/security-advisories?per_page=100&state=published")
        hits = []
        for a in advisories:
            for vuln in a.get("vulnerabilities") or []:
                spec = vuln.get("vulnerable_version_range") or ""
                if spec and in_range(v, spec):
                    hits.append(f"{a.get('cve_id') or a['ghsa_id']} ({a.get('severity')}): {spec}, fixed in {vuln.get('patched_versions')}")
        print(f"{name} {pinned}: {len(advisories)} advisories, " + ("AFFECTED" if hits else "none apply"))
        for h in hits:
            print("    " + h)
        if hits:
            affected.append(name)

    m = BORINGSSL.search(zon)
    if not m:
        stale.append("boringssl")
    else:
        commit = m.group(1)
        vulns = fetch("https://api.osv.dev/v1/query", {"commit": commit}).get("vulns", [])
        print(f"boringssl {commit[:8]}: OSV " + ("AFFECTED" if vulns else "none known at this commit"))
        for x in vulns:
            print(f"    {x['id']}: {x.get('summary', '')}")
        if vulns:
            affected.append("boringssl")

    if stale:
        print("pin changed, update tools/advisories.py: " + ", ".join(stale))
        return 2
    return 1 if affected else 0


if __name__ == "__main__":
    sys.exit(main())
