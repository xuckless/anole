#!/usr/bin/env python3
"""Fail if a test gated on a live-server URL is reached by no live step.

A test that needs a server skips itself without the URL
(`features.<service>_test_url orelse return error.SkipZigTest`), so a live
step whose `-Dtest-filter`-style filter misses it passes while running
nothing. This lists every such test and checks that the filters of that
service's build.zig step (`test-postgres`, `test-redis`, ...) match it by
substring of its name or of its module path (`nats.live_test`), the way
Zig's `--test-filter` does. Generic suites whose test names are generated
(`Suite(.postgres)`) are matched on that text.

No zig needed; run from the repository root:  python3 -I tools/live_coverage.py
(research/s15/test-audit.md, T10.)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# service -> (tokens that gate a test on the server, build.zig test name)
SERVICES = {
    "postgres": (["postgres_test_url"], "anole-test-pg"),
    "redis": (["redis_test_url", "redis_url", "redis_test_port"], "anole-test-redis"),
    "mongodb": (["mongodb_test_url"], "anole-test-mongodb"),
    "nats": (["nats_test_url"], "anole-test-nats"),
    "kafka": (["kafka_test_url"], "anole-test-kafka"),
    "s3": (["s3_test_url"], "anole-test-s3"),
}

TEST_RE = re.compile(r'^\s*test\s+"((?:[^"\\]|\\.)*)"\s*\{', re.M)


def filters_of(build_zig: str, test_name: str) -> list[str] | None:
    m = re.search(r'\.name\s*=\s*"%s"[^\n]*?\.filters\s*=\s*([^\n]*?)(?:,\s*\.use_llvm|\s*\}\))' % re.escape(test_name), build_zig)
    if not m:
        return None
    expr = m.group(1)
    # `&.{ "a", "b" }` or `if (test_filters.len > 0) test_filters else &.{ "a", "b" }`
    expr = expr.split(" else ")[-1]
    return re.findall(r'"((?:[^"\\]|\\.)*)"', expr)


def blocks(text: str):
    """(name, body) of each test; a body ends at the closing brace at the
    test's own indentation."""
    for m in TEST_RE.finditer(text):
        at = m.start() + m.group(0).index("test")
        line_start = text.rfind("\n", 0, at) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        end = text.find("\n" + indent + "}", m.end())
        yield m.group(1), text[m.end(): end if end >= 0 else len(text)]


def main() -> int:
    build = (ROOT / "build.zig").read_text()
    problems = []
    checked = 0
    for svc, (tokens, step_test) in SERVICES.items():
        filters = filters_of(build, step_test)
        if filters is None:
            problems.append(f"{svc}: build.zig has no test named {step_test} with a filter list")
            continue
        for path in sorted((ROOT / "src").rglob("*.zig")):
            text = path.read_text()
            if not any(t in text for t in tokens):
                continue
            rel = path.relative_to(ROOT / "src").with_suffix("")
            modpath = ".".join(rel.parts)
            generic = "Suite(" in text
            if generic:
                # Generated names (jobs' conformance Suite): reached if a
                # filter names this service's instance.
                checked += 1
                if not any(f"Suite(.{svc})" in f for f in filters):
                    problems.append(f"{svc}: {rel}.zig has a generic Suite(.{svc}) and no filter of {step_test} names it")
                continue
            all_tests = [n for n, _ in blocks(text)]
            gated = [n for n, body in blocks(text) if any(t in body for t in tokens)]
            if not gated:
                # Gated through a file-level helper: every test of the file.
                gated = all_tests
            for name in gated:
                checked += 1
                if not any(f in name or f in modpath for f in filters):
                    problems.append(f'{svc}: test "{name}" in {rel}.zig matches none of {step_test}\'s filters {filters}')
    for p in problems:
        print("live_coverage:", p, file=sys.stderr)
    if problems:
        print(f"live_coverage: {len(problems)} problem(s) in {checked} gated tests", file=sys.stderr)
        return 1
    print(f"live_coverage: {checked} live-gated tests, all reached by their service's filters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
