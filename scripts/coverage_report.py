#!/usr/bin/env python3
"""coverage_report.py: per-file -> per-target coverage math for scripts/coverage-report.sh (#0212). Stdlib only, run with -I.

Inputs: `xcrun llvm-cov report` text reports (one per package, --llvm PACKAGE=FILE) and `xcrun xccov view --report --json`
reports of the app's xcresult bundles (--xccov FILE, repeatable; the max per file is taken across bundles).
Writes <out>/report.md, <out>/lowest.txt, <out>/summary.txt and <out>/packages.txt. Exits 1 when a target with a floor is
under it (`coverage: FLOOR <target> <pct> < <floor>`) or has no files measured (`coverage: MISSING <target>`).
"""
import argparse
import json
import re
import sys
from pathlib import Path

# Floors that change with the tier: the real-time AudioCore tests only run in --full.
TIER_FLOORS = {"full": {"AudioCore": 80}}
# Targets that are test support, tools or C shims: reported, never in a package's number.
NON_PRODUCT = re.compile(r"Stub$|TestFixtures$|^skintool$|^CAtomics$")
TEST_PATH = re.compile(r"(^|/)(Tests|[A-Za-z]+Tests|[A-Za-z]+UITests)/|\.build/|/DerivedData/")
LOWEST_COUNT = 20
LOWEST_MIN_LINES = 40


def parse_llvm_report(text):
    """Rows of `llvm-cov report`: Filename Regions Missed Cover Functions Missed Executed Lines Missed Cover [Branches…]."""
    files = {}
    for line in text.splitlines():
        tok = line.split()
        if len(tok) < 10 or tok[0] == "TOTAL" or not tok[1].isdigit():
            continue
        try:
            lines, missed = int(tok[7]), int(tok[8])
        except ValueError:
            continue
        files[tok[0]] = (lines, lines - missed)
    return files


def parse_xccov(text):
    """`xccov view --report --json`: targets[].files[] with path, executableLines, coveredLines."""
    data = json.loads(text)
    files = {}
    for target in data.get("targets", []):
        for f in target.get("files", []):
            path = f.get("path") or f.get("name", "")
            files[path] = (int(f.get("executableLines", 0)), int(f.get("coveredLines", 0)))
    return files


def package_target(path):
    """Sources/<Target>/…, absolute or relative. `llvm-cov report` strips the common prefix of every file it lists, so a
    package whose sources span several targets comes back as `<Target>/…` (the prefix ends in `Sources/`, #0212's first
    run): a relative path with no `Sources/` in it is keyed by its first component."""
    m = re.search(r"(?:^|/)Sources/([^/]+)/", path)
    if m:
        return m.group(1), path[m.start():].lstrip("/")
    if not path.startswith("/") and "/" in path:
        return path.split("/", 1)[0], f"Sources/{path}"
    return None, path


def app_path(path):
    m = re.search(r"(?:^|/)(App/.+)$", path)
    return m.group(1) if m else None


def collect(llvm, xccov):
    """llvm: {package: text}; xccov: [text]. Returns [(package, target, relpath, lines, covered)]."""
    rows = []
    for package, text in llvm.items():
        for path, (lines, covered) in parse_llvm_report(text).items():
            if TEST_PATH.search(path):
                continue
            target, rel = package_target(path)
            if target:
                rows.append((package, target, f"Packages/{package}/{rel}", lines, covered))
    app = {}
    for text in xccov:
        for path, (lines, covered) in parse_xccov(text).items():
            rel = app_path(path)
            if rel is None or TEST_PATH.search(rel):
                continue
            old = app.get(rel)
            if old is None or covered > old[1]:
                app[rel] = (lines, covered)
    rows += [("App", "App", rel, lines, covered) for rel, (lines, covered) in app.items()]
    return rows


def pct(covered, lines):
    return 100.0 * covered / lines if lines else 0.0


def read_floors(text, tier):
    floors = {}
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        target, floor = line.split()
        floors[target] = float(floor)
    floors.update(TIER_FLOORS.get(tier, {}))
    return floors


def aggregate(rows):
    targets, packages = {}, {}
    for package, target, _, lines, covered in rows:
        t = targets.setdefault(target, [package, 0, 0])
        t[1] += lines
        t[2] += covered
        if not NON_PRODUCT.search(target):
            p = packages.setdefault(package, [0, 0])
            p[0] += lines
            p[1] += covered
    return targets, packages


def lowest(rows):
    big = [r for r in rows if r[3] > LOWEST_MIN_LINES and not NON_PRODUCT.search(r[1])]
    big.sort(key=lambda r: (pct(r[4], r[3]), -r[3], r[2]))
    return big[:LOWEST_COUNT]


def fmt(p):
    return f"{p:.0f}%"


def report(rows, floors, tier, out):
    targets, packages = aggregate(rows)
    out.mkdir(parents=True, exist_ok=True)
    breaches, md, summary = [], [], []
    md += [f"# Coverage ({tier} tier)", "", "| Target | Package | Lines | Covered | % | Floor | Status |", "|---|---|---|---|---|---|---|"]
    order = sorted(targets, key=lambda t: (targets[t][0], t))
    for target in order:
        package, lines, covered = targets[target]
        p = pct(covered, lines)
        floor = floors.get(target)
        status = "—"
        if floor is not None:
            status = "ok" if p >= floor else "**under**"
            if p < floor:
                breaches.append(f"coverage: FLOOR {target} {p:.1f}% < {floor:g}%")
        md.append(f"| {target} | {package} | {lines} | {covered} | {p:.1f}% | {'' if floor is None else f'{floor:g}%'} | {status} |")
        summary.append(f"coverage: {target} {p:.1f}%")
    for target in sorted(set(floors) - set(targets)):
        # A floored target with no rows means the measurement broke (#0212's first run: every package MISSING): fail.
        breaches.append(f"coverage: MISSING {target} (no files measured)")
    pkg_order = [p for p in ("SkinKit", "PlayerKit", "App") if p in packages] + sorted(set(packages) - {"SkinKit", "PlayerKit", "App"})
    packages_line = "  ".join(f"{p} {fmt(pct(packages[p][1], packages[p][0]))}" for p in pkg_order)
    low = lowest(rows)
    low_lines = [f"{pct(c, l):5.1f}%  {l:5d}  {path}" for _, _, path, l, c in low]
    md += ["", f"## Twenty least-covered files (over {LOWEST_MIN_LINES} lines)", "", "```", *low_lines, "```", ""]
    (out / "report.md").write_text("\n".join(md) + "\n")
    (out / "lowest.txt").write_text("\n".join(low_lines) + "\n")
    (out / "summary.txt").write_text("\n".join(summary + breaches) + "\n")
    (out / "packages.txt").write_text(packages_line + "\n")
    return summary, breaches, packages_line


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--llvm", action="append", default=[], help="PACKAGE=llvm-cov report text file")
    ap.add_argument("--xccov", action="append", default=[], help="xccov --json report file")
    ap.add_argument("--floors", type=Path)
    ap.add_argument("--tier", default="fast")
    a = ap.parse_args(argv)
    llvm = {}
    for spec in a.llvm:
        package, _, path = spec.partition("=")
        llvm[package] = Path(path).read_text()
    xccov = [Path(p).read_text() for p in a.xccov]
    floors = read_floors(a.floors.read_text(), a.tier) if a.floors else dict(TIER_FLOORS.get(a.tier, {}))
    summary, breaches, packages_line = report(collect(llvm, xccov), floors, a.tier, a.out)
    for line in summary + breaches:
        print(line)
    print(f"coverage: packages {packages_line}")
    return 1 if breaches else 0


if __name__ == "__main__":
    sys.exit(main())
