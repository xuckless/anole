#!/usr/bin/env python3
"""Check that every live-service test runs in some CI step (TESTING.md W2).

    tools/live_coverage.py [--list]

A live-service test reads a service's build option (`postgres_test_url`,
`redis_test_url`/`redis_test_port`, `mongodb_test_url`, `nats_test_url`,
`kafka_test_url`, `s3_test_url`, `smtp_test_url`/`mailpit_api_url`) in its
body, or through a declaration that does (a helper function or constant in
the same file, or a `pub` one of another file reached through an
`@import` alias). Without the option the test skips, so it only runs in a CI
step that passes the option to a build step whose compile-time test filters
let it in.

The script works out:
- each live test's fully qualified name (`<file path with dots>.test.<name>`,
  `<file>.Suite(.postgres).test.<name>` for a test in a generic suite;
  only the instances whose argument names the service count);
- the CI steps that pass each option: ci.yml's `zig build` lines and the
  `tests/*/run.sh` scripts it runs, each `zig build <step> -D<svc>-test-url`;
- each build step's filters, from build.zig (`addSafeTest(.. .filters =
  &.{..})` behind `b.step("<step>", ..)`); `test` with `-Dtest-filter` uses
  those filters, and without one runs everything.

It fails (exit 1) when a live test's name contains none of the filters of the
steps that pass its option, and names the test and the steps. No zig needed.
test-audit.md 4.4 and T10 (research/s15).
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# build option field -> service, and the -D option that sets it.
FIELDS = {
    "postgres_test_url": "postgres",
    "redis_test_url": "redis",
    "redis_test_port": "redis",
    "mongodb_test_url": "mongodb",
    "nats_test_url": "nats",
    "kafka_test_url": "kafka",
    "s3_test_url": "s3",
    "smtp_test_url": "smtp",
    "mailpit_api_url": "smtp",
}
OPTIONS = {f.replace("_", "-"): s for f, s in FIELDS.items()}
FIELD_RE = re.compile(r"\b(" + "|".join(FIELDS) + r")\b")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def strip_comments(src):
    # Line comments only (Zig has no block comments); keep string literals.
    out = []
    for line in src.split("\n"):
        i = 0
        in_str = False
        while i < len(line):
            c = line[i]
            if in_str:
                if c == "\\":
                    i += 2
                    continue
                if c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif line.startswith("//", i) and not line.lstrip().startswith("\\\\"):
                line = line[:i]
                break
            i += 1
        out.append(line)
    return "\n".join(out)


def block_end(src, open_brace):
    """Index just past the brace that closes the one at open_brace."""
    depth = 0
    i = open_brace
    in_str = False
    while i < len(src):
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"' or c == "\n":
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(src)


TOP_DECL_RE = re.compile(r"^(?:pub\s+)?(?:inline\s+)?(?:const|var|fn)\s+(@?\"?[A-Za-z_][\w]*)", re.M)
IMPORT_RE = re.compile(r"\b(?:const|var)\s+(\w+)\s*=\s*@import\(\"([^\"]+\.zig)\"\)")
TOP_ITEM_RE = re.compile(r"^(?:test\b|comptime\b)", re.M)
TEST_RE = re.compile(r"^([ \t]*)test\s+\"((?:[^\"\\]|\\.)*)\"\s*\{", re.M)
GENERIC_FN_RE = re.compile(r"^(?:pub\s+)?fn\s+(\w+)\s*\(\s*comptime\b[^)]*\)\s*type\s*\{", re.M)


class File:
    def __init__(self, path):
        self.path = path
        self.src = strip_comments(read(path))
        rel = os.path.relpath(path, os.path.join(ROOT, "src"))
        self.ns = rel[: -len(".zig")].replace(os.sep, ".")
        # Top-level declarations: name -> text (to the next top-level one).
        self.decls = {}
        # A declaration ends where the next top-level item (declaration,
        # test or comptime block) starts.
        starts = [(m.start(), m.group(1)) for m in TOP_DECL_RE.finditer(self.src)]
        bounds = sorted({st for st, _ in starts} | {m.start() for m in TOP_ITEM_RE.finditer(self.src)} | {len(self.src)})
        for start, name in starts:
            end = next(b for b in bounds if b > start)
            text = self.src[start:end]
            # Functions, and namespaces of them (`const E2E = struct { fn run .. }`).
            callable = re.match(r"(?:pub\s+)?(?:inline\s+)?(?:fn\b|const\s+\w+\s*=\s*(?:struct|union|enum)\b)", text) is not None
            self.decls[name] = (text, callable)
        # Aliases of other files: alias -> absolute path (anywhere in the file).
        self.aliases = {}
        for m in IMPORT_RE.finditer(self.src):
            target = os.path.normpath(os.path.join(os.path.dirname(path), m.group(2)))
            self.aliases[m.group(1)] = target
        # Generic suites: fn name -> (start, end, instance arguments).
        self.generics = []
        for m in GENERIC_FN_RE.finditer(self.src):
            end = block_end(self.src, m.end() - 1)
            args = re.findall(r"\b" + re.escape(m.group(1)) + r"\(\.(\w+)\)", self.src)
            self.generics.append((m.group(1), m.start(), end, sorted(set(args))))
        self.tests = []
        for m in TEST_RE.finditer(self.src):
            body = self.src[m.end() - 1 : block_end(self.src, m.end() - 1)]
            self.tests.append((m.start(), m.group(2), body))
        self.taint = {}  # decl name -> set of services


def services_of(text, f, files):
    """(direct, indirect): the services whose options the text reads itself
    or through a constant, and those it reaches through a function (which
    may read the option only for some arguments)."""
    direct = {FIELDS[m.group(1)] for m in FIELD_RE.finditer(text)}
    indirect = set()

    def add(svcs, is_fn):
        (indirect if is_fn else direct).update(svcs)

    for name, svcs in f.taint.items():
        if svcs and re.search(r"(?<![\w.])" + re.escape(name) + r"\b", text):
            add(svcs, f.decls[name][1])
    for alias, target in f.aliases.items():
        other = files.get(target)
        if not other:
            continue
        for name, svcs in other.taint.items():
            if svcs and re.search(r"\b" + re.escape(alias) + r"\." + re.escape(name) + r"\b", text):
                add(svcs, other.decls[name][1])
    return direct, indirect


# Words in a test's name that say which service it is about.
NAMED = {
    "postgres": re.compile(r"postgres|\bpg\b", re.I),
    "redis": re.compile(r"redis|valkey", re.I),
    "mongodb": re.compile(r"mongo", re.I),
    "nats": re.compile(r"nats", re.I),
    "kafka": re.compile(r"kafka|redpanda", re.I),
    "s3": re.compile(r"\bs3\b", re.I),
    "smtp": re.compile(r"smtp|mailpit", re.I),
}


def test_services(name, body, f, files):
    """The services a test needs. A function reached from the body may read
    an option for some arguments only (`run(.memory)` beside
    `run(.redis)`), so a service reached only that way counts when the test's
    name names it, or, in a `*live*` file, when the name names no service."""
    direct, indirect = services_of(body, f, files)
    named = {s for s, rx in NAMED.items() if rx.search(name)}
    if "live" in os.path.basename(f.path) and not named:
        return direct | indirect
    return direct | (indirect & named)


def live_tests(files):
    changed = True
    while changed:
        changed = False
        for f in files.values():
            for name, (text, _) in f.decls.items():
                d, i = services_of(text, f, files)
                s = d | i
                if s - f.taint.get(name, set()):
                    f.taint[name] = f.taint.get(name, set()) | s
                    changed = True
    out = []  # (qualified name, service, path:line)
    for f in files.values():
        for start, name, body in f.tests:
            line = f.src.count("\n", 0, start) + 1
            where = f"{os.path.relpath(f.path, ROOT)}:{line}"
            generic = next((g for g in f.generics if g[1] < start < g[2]), None)
            if generic:
                # A test of a generic suite gets its fixture from the suite's
                # own functions: what the whole suite reaches, for the
                # instances whose argument names a service.
                gname, gstart, gend, args = generic
                d, i = services_of(f.src[gstart:gend], f, files)
                svcs = d | i
                for arg in args:
                    if arg in svcs:
                        out.append((f"{f.ns}.{gname}(.{arg}).test.{name}", arg, where))
            else:
                svcs = test_services(name, body, f, files)
                for svc in sorted(svcs):
                    out.append((f"{f.ns}.test.{name}", svc, where))
    return out


# ---------------------------------------------------------------- build.zig


def step_filters():
    """Build step name -> list of filters (None: the whole suite)."""
    src = strip_comments(read(os.path.join(ROOT, "build.zig")))
    tests = {}
    for m in re.finditer(r"const\s+(\w+)\s*=\s*addSafeTest\(b,\s*\.\{(.*?)\}\);", src, re.S):
        fm = re.search(r"\.filters\s*=\s*(.*?)(?:,\s*\.use_llvm|$)", m.group(2), re.S)
        if fm:
            lits = re.findall(r"\"((?:[^\"\\]|\\.)*)\"", fm.group(1))
            tests[m.group(1)] = [bytes(x, "utf-8").decode("unicode_escape") for x in lits]
    runs = {m.group(1): m.group(2) for m in re.finditer(r"const\s+(\w+)\s*=\s*b\.addRunArtifact\((\w+)\)", src)}
    steps = {}
    for m in re.finditer(r"b\.step\(\"([\w-]+)\"[^;]*?\.dependOn\(&(?:b\.addRunArtifact\((\w+)\)|(\w+))\.step\)", src, re.S):
        var = m.group(2) or runs.get(m.group(3))
        if var in tests:
            steps[m.group(1)] = tests[var]
    steps["test"] = None
    return steps


# ---------------------------------------------------------------- CI


def ci_invocations():
    """(service, step, test filters or None, where) for each CI build that passes a service option."""
    ci = read(os.path.join(ROOT, ".github", "workflows", "ci.yml"))
    sources = [(".github/workflows/ci.yml", ci)]
    for script in sorted(set(re.findall(r"\b(tests/[\w/.-]+/run\.sh)\b", ci))):
        p = os.path.join(ROOT, script)
        if os.path.exists(p):
            sources.append((script, read(p)))
    out = []
    for where, text in sources:
        text = text.replace("\\\n", " ")
        for n, line in enumerate(text.split("\n"), 1):
            if line.lstrip().startswith("#"):
                continue
            m = re.search(r"(?:\bzig|\"\$ZIG\"|\"\$zig\"|\$ZIG)\s+build\s+(.*)", line)
            if not m:
                continue
            args = m.group(1)
            opts = {OPTIONS[o] for o in re.findall(r"-D([\w-]+)=", args) if o in OPTIONS}
            if not opts:
                continue
            filters = re.findall(r"-Dtest-filter=(?:\"([^\"]*)\"|'([^']*)'|(\S+))", args)
            filters = [a or b or c for a, b, c in filters] or None
            # The step names come first: `zig build <step>... -D.. --summary all`.
            for step in re.split(r"\s+", args.strip()):
                if not re.fullmatch(r"\w[\w-]*", step):
                    break
                for svc in opts:
                    out.append((svc, step, filters, f"{where}:{n}"))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--list", action="store_true", help="print every live test and the step that runs it")
    args = ap.parse_args()

    files = {}
    for dirpath, _, names in os.walk(os.path.join(ROOT, "src")):
        for name in names:
            if name.endswith(".zig"):
                p = os.path.normpath(os.path.join(dirpath, name))
                files[p] = File(p)

    steps = step_filters()
    invocations = ci_invocations()
    missing = []
    tests = live_tests(files)
    for qname, svc, where in sorted(tests):
        runners = []
        for isvc, step, filters, at in invocations:
            if isvc != svc:
                continue
            if step == "test":
                fl = filters
            elif step in steps:
                fl = steps[step] if filters is None or steps[step] is None else steps[step]
            else:
                continue
            if fl is None or any(x in qname for x in fl):
                runners.append(f"{step} ({at})")
        if args.list:
            print(f"{svc:9} {qname}\n          {where} -> {', '.join(runners) or 'NONE'}")
        if not runners:
            missing.append((qname, svc, where))

    print(f"{len(tests)} live tests, {len(missing)} with no CI step")
    for qname, svc, where in missing:
        steps_for = sorted({f"{step}{'' if f is None else ' -Dtest-filter=' + ','.join(f)}" for s, step, f, _ in invocations if s == svc})
        print(f"  {where}: {qname}\n    needs {svc}; the CI steps that pass it ({', '.join(steps_for) or 'none'}) filter it out")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
