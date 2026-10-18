"""Summarises an Autobahn run; exits 1 on any failing case, or when the
report holds fewer cases than wstest announced (a run cut short)."""
import collections, json, re, sys

index = json.load(open(sys.argv[1]))
announced = None
if len(sys.argv) > 2:
    m = re.search(r"will run (\d+) test cases", open(sys.argv[2]).read())
    announced = int(m.group(1)) if m else None
ok = {"OK", "NON-STRICT", "INFORMATIONAL"}
counts = collections.Counter()
bad = []
cases = index.get("anole", {})
for case, result in sorted(cases.items(), key=lambda kv: [int(p) for p in kv[0].split(".")]):
    for key in ("behavior", "behaviorClose"):
        counts[(key, result[key])] += 1
    if result["behavior"] not in ok or result["behaviorClose"] not in ok:
        bad.append(f"{case}: {result['behavior']} / {result['behaviorClose']}")
print(f"{len(cases)} cases (announced {announced});", dict(sorted(counts.items())))
for line in bad:
    print("FAIL", line)
short = announced is not None and len(cases) < announced
if short:
    print(f"FAIL only {len(cases)} of {announced} cases ran")
sys.exit(1 if bad or short else 0)
