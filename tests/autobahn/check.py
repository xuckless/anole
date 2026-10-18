"""Summarises an Autobahn index.json; exits 1 on any failing case."""
import collections, json, sys

index = json.load(open(sys.argv[1]))
ok = {"OK", "NON-STRICT", "INFORMATIONAL"}
counts = collections.Counter()
bad = []
for agent, cases in index.items():
    for case, result in sorted(cases.items(), key=lambda kv: [int(p) for p in kv[0].split(".")]):
        for key in ("behavior", "behaviorClose"):
            counts[(key, result[key])] += 1
        if result["behavior"] not in ok or result["behaviorClose"] not in ok:
            bad.append(f"{case}: {result['behavior']} / {result['behaviorClose']}")
print(f"{sum(1 for _ in index.get('anole', {}))} cases;", dict(sorted(counts.items())))
for line in bad:
    print("FAIL", line)
sys.exit(1 if bad else 0)
