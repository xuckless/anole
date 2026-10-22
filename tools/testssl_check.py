#!/usr/bin/env python3
"""Fail on a weak TLS configuration in a testssl.sh JSON report.

    tools/testssl_check.py report.json

Fails on: SSLv2/SSLv3/TLS 1.0/TLS 1.1 offered, NULL/EXPORT/anonymous/RC4/3DES
ciphers offered, any vulnerability check reported VULNERABLE, no forward
secrecy. Certificate-trust findings are ignored (the dev certificate is
self-signed). BREACH is reported by testssl for any HTTP compression and is
informational here, so it never fails the check.
"""
import json
import sys

OLD_PROTOCOLS = {"SSLv2", "SSLv3", "TLS1", "TLS1_1"}
BAD_CIPHER_GROUPS = {"cipherlist_NULL", "cipherlist_aNULL", "cipherlist_EXPORT",
                     "cipherlist_3DES_IDEA", "RC4"}
SKIP_VULN = {"BREACH"}


def main(path):
    with open(path) as f:
        items = json.load(f)
    if isinstance(items, dict):
        items = items.get("scanResult", [{}])[0].get("findings", []) if "scanResult" in items else []
    by_id = {i["id"]: i for i in items if "id" in i}
    problems = []
    for i in items:
        id_, finding = i.get("id", ""), i.get("finding", "")
        low = finding.lower()
        if id_ in OLD_PROTOCOLS and "not offered" not in low:
            problems.append(f"{id_} offered: {finding}")
        elif id_ in BAD_CIPHER_GROUPS and "not offered" not in low and "not vulnerable" not in low:
            problems.append(f"{id_}: {finding}")
        elif id_ not in SKIP_VULN and "VULNERABLE" in finding and "not vulnerable" not in low:
            problems.append(f"{id_} vulnerable: {finding}")
        elif id_.startswith("cert_") and False:
            pass
    fs = by_id.get("FS")
    if fs is None:
        problems.append("no forward secrecy result in the report")
    elif "not offered" in fs.get("finding", "").lower() or "offered" not in fs.get("finding", "").lower():
        problems.append(f"forward secrecy: {fs.get('finding')}")
    tls = [p for p in ("TLS1_2", "TLS1_3") if "offered" in by_id.get(p, {}).get("finding", "").lower()
           and "not offered" not in by_id[p]["finding"].lower()]
    if not tls:
        problems.append("neither TLS 1.2 nor TLS 1.3 offered")
    if problems:
        print("testssl.sh found problems:")
        for p in problems:
            print("  -", p)
        return 1
    print(f"testssl.sh: ok ({len(items)} findings, offered: {', '.join(tls)})")
    return 0


sys.exit(main(sys.argv[1]))
