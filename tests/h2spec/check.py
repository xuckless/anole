"""Compares h2spec JUnit reports with tests/h2spec/known-failures.txt.

Usage: python3 check.py known-failures.txt report.xml [report.xml ...]
Exits non-zero on a failure that is not listed, or a listed case that passed
in every report (so the list never outlives the reason for it).
"""
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    known_path, reports = sys.argv[1], sys.argv[2:]
    known = set()
    with open(known_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                package, _, case = line.partition(" | ")
                known.add((package.strip(), case.strip()))

    ok = True
    for report in reports:
        failed, total = set(), 0
        try:
            tree = ET.parse(report)
        except (OSError, ET.ParseError) as err:
            # h2spec writes no report when it gives up (a connection that
            # hangs past its timeout, or a server that died).
            print(f"{report}: no report ({err}); h2spec did not finish")
            ok = False
            continue
        for tc in tree.iter("testcase"):
            total += 1
            if tc.find("failure") is not None or tc.find("error") is not None:
                failed.add((tc.get("package"), tc.get("classname")))
        unexpected = failed - known
        fixed = known - failed
        print(f"{report}: {total} cases, {len(failed)} failed ({len(failed & known)} known)")
        for p, c in sorted(unexpected):
            print(f"  NEW FAILURE: {p} | {c}")
            ok = False
        for p, c in sorted(fixed):
            print(f"  NOW PASSING (remove from the list): {p} | {c}")
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
