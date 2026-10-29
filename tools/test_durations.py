#!/usr/bin/env python3
"""Summarize the per-test durations the test runners record.

    rm -f /tmp/d.tsv
    ANOLE_TEST_DURATIONS=/tmp/d.tsv zig build test -Dtest-shards=4
    tools/test_durations.py /tmp/d.tsv [--top 30] [--budget 60] [--per-test 1]

Each line of the file is `<ns>\\t<result>\\t<test name>\\t<binary>`, written by
src/safety/test_runner.zig and src/http/core/test_runner.zig (binary is the
executable's name, plus `#i/n` for a shard of `-Dtest-shards`). Prints:

- the slowest tests;
- how many took over 100 ms (TESTING.md W1) and over 1 s, and the over-1 s list;
- the total per binary and per shard;
- the total per namespace (the part of the name before `.test.`, which is
  the file the test is in);
- the critical path: the slowest shard's total, the lower bound on the
  suite's wall time when every binary and shard runs in parallel.

`--budget S` and `--per-test S` turn the K1 budget (test-audit.md 5.3) into
an exit code: 1 when the critical path is over S seconds or any test is over
the per-test limit. Local only: the durations never gate CI (TESTING.md D6).
"""
import argparse
import collections
import sys

NS_PER_S = 1_000_000_000


def fmt(ns):
    if ns >= NS_PER_S:
        return f"{ns / NS_PER_S:8.2f} s "
    return f"{ns / 1_000_000:8.1f} ms"


def load(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                print(f"{path}:{n}: expected <ns>\\t<result>\\t<name>[\\t<binary>]", file=sys.stderr)
                continue
            try:
                ns = int(parts[0])
            except ValueError:
                print(f"{path}:{n}: not a duration: {parts[0]!r}", file=sys.stderr)
                continue
            binary = parts[3] if len(parts) > 3 else "?"
            rows.append((ns, parts[1], parts[2], binary))
    return rows


def namespace(name):
    i = name.find(".test.")
    return name[:i] if i >= 0 else name.split(".", 1)[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("file")
    ap.add_argument("--top", type=int, default=30, help="how many of the slowest tests to list (30)")
    ap.add_argument("--namespaces", type=int, default=25, help="how many namespaces to list (25)")
    ap.add_argument("--budget", type=float, help="fail when the critical path is over this many seconds")
    ap.add_argument("--per-test", type=float, help="fail when a test is over this many seconds")
    args = ap.parse_args()

    rows = load(args.file)
    if not rows:
        print(f"{args.file}: no durations")
        return 1

    rows.sort(key=lambda r: r[0], reverse=True)
    results = collections.Counter(r[1] for r in rows)
    total = sum(r[0] for r in rows)
    print(f"{len(rows)} tests, {fmt(total).strip()} in all ({', '.join(f'{k} {v}' for k, v in sorted(results.items()))})")

    print(f"\nSlowest {min(args.top, len(rows))}:")
    for ns, result, name, binary in rows[: args.top]:
        print(f"  {fmt(ns)}  {result:4}  {binary:24}  {name}")

    over_100ms = [r for r in rows if r[0] > 100_000_000]
    over_1s = [r for r in rows if r[0] > NS_PER_S]
    print(f"\nOver 100 ms (W1): {len(over_100ms)}; over 1 s: {len(over_1s)}")
    for ns, result, name, binary in over_1s:
        print(f"  {fmt(ns)}  {binary:24}  {name}")

    per_shard = collections.defaultdict(int)
    per_binary = collections.defaultdict(int)
    counts = collections.Counter()
    for ns, _, _, binary in rows:
        per_shard[binary] += ns
        per_binary[binary.split("#", 1)[0]] += ns
        counts[binary] += 1
    print("\nPer binary (sum of its tests; shards below):")
    for binary, ns in sorted(per_binary.items(), key=lambda kv: kv[1], reverse=True):
        print(f"  {fmt(ns)}  {binary}")
        shards = sorted(b for b in per_shard if b.startswith(binary + "#"))
        for s in shards:
            print(f"      {fmt(per_shard[s])}  {s} ({counts[s]} tests)")

    per_ns = collections.defaultdict(int)
    for ns, _, name, _ in rows:
        per_ns[namespace(name)] += ns
    print(f"\nPer namespace (top {args.namespaces}):")
    for name, ns in sorted(per_ns.items(), key=lambda kv: kv[1], reverse=True)[: args.namespaces]:
        print(f"  {fmt(ns)}  {name}")

    critical_binary, critical = max(per_shard.items(), key=lambda kv: kv[1])
    print(f"\nCritical path: {fmt(critical).strip()} ({critical_binary}; compile time and process start not included)")

    failed = False
    if args.budget is not None and critical > args.budget * NS_PER_S:
        print(f"OVER BUDGET: the critical path is over {args.budget:g} s")
        failed = True
    if args.per_test is not None:
        limit = args.per_test * NS_PER_S
        slow = [r for r in rows if r[0] > limit]
        if slow:
            print(f"OVER THE PER-TEST LIMIT: {len(slow)} test(s) over {args.per_test:g} s")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
