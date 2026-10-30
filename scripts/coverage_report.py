#!/usr/bin/env python3
"""coverage_report.py: per-file -> per-target coverage math for scripts/coverage-report.sh (#0212). Stdlib only, run with -I.

Inputs: `xcrun llvm-cov report` text reports (one per package, --llvm PACKAGE=FILE) and `xcrun xccov view --report --json`
reports of the app's xcresult bundles (--xccov FILE, repeatable; the max per file is taken across bundles; within a
bundle a file's Roadie.app row wins; App/TestSupport/ is left out).
Writes <out>/report.md, <out>/lowest.txt, <out>/summary.txt and <out>/packages.txt. Exits 1 when a target with a floor is
under it (`coverage: FLOOR <target> <pct> < <floor>`) or has no files measured (`coverage: MISSING <target>`).
--partial TARGET=REASON (repeatable) marks a target whose measurement is incomplete (the App when the UI tests didn't
finish): it prints `coverage: PARTIAL <target> <pct> (floor not checked: REASON)`, its floor is neither a FLOOR nor a
MISSING failure, and its package's number in packages.txt says `(partial)`.
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
# App sources compiled only for tests (stand-ins, scripted servers; Debug-only): not product code, never counted.
APP_TEST_ONLY = re.compile(r"^App/TestSupport/")
# The app's own target in an xcresult. A file compiled into it and into a test bundle too (`App/Accessibility/AXID.swift`
# is also in RoadieUITests.xctest) is listed under both; only this target's row counts.
APP_TARGET = "Roadie.app"
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
    """`xccov view --report --json`: targets[].files[] with path, executableLines, coveredLines. A path listed under
    several targets of one bundle keeps its `APP_TARGET` row, else its first."""
    data = json.loads(text)
    files, from_app = {}, set()
    for target in data.get("targets", []):
        is_app = target.get("name") == APP_TARGET
        for f in target.get("files", []):
            path = f.get("path") or f.get("name", "")
            if path in from_app or (path in files and not is_app):
                continue
            files[path] = (int(f.get("executableLines", 0)), int(f.get("coveredLines", 0)))
            if is_app:
                from_app.add(path)
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
            if rel is None or TEST_PATH.search(rel) or APP_TEST_ONLY.search(rel):
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


def report(rows, floors, tier, out, partial=None):
    partial = partial or {}
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
        if target in partial:
            status = "partial"
            breaches.append(f"coverage: PARTIAL {target} {p:.1f}% (floor {'none' if floor is None else f'{floor:g}%'} "
                            f"not checked: {partial[target]})")
        elif floor is not None:
            status = "ok" if p >= floor else "**under**"
            if p < floor:
                breaches.append(f"coverage: FLOOR {target} {p:.1f}% < {floor:g}%")
        md.append(f"| {target} | {package} | {lines} | {covered} | {p:.1f}% | {'' if floor is None else f'{floor:g}%'} | {status} |")
        summary.append(f"coverage: {target} {p:.1f}%")
    for target in sorted(set(partial) - set(targets)):
        breaches.append(f"coverage: PARTIAL {target} (nothing measured; floor not checked: {partial[target]})")
    for target in sorted(set(floors) - set(targets) - set(partial)):
        # A floored target with no rows means the measurement broke (#0212's first run: every package MISSING): fail.
        breaches.append(f"coverage: MISSING {target} (no files measured)")
    pkg_order = [p for p in ("SkinKit", "PlayerKit", "App") if p in packages] + sorted(set(packages) - {"SkinKit", "PlayerKit", "App"})
    partial_packages = {targets[t][0] if t in targets else t for t in partial}
    packages_line = "  ".join(f"{p} {fmt(pct(packages[p][1], packages[p][0]))}{' (partial)' if p in partial_packages else ''}"
                              for p in pkg_order)
    low = lowest(rows)
    low_lines = [f"{pct(c, l):5.1f}%  {l:5d}  {path}" for _, _, path, l, c in low]
    for target, reason in sorted(partial.items()):
        md += ["", f"**Partial:** {target}'s number is incomplete ({reason}); its floor was not checked."]
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
    ap.add_argument("--partial", action="append", default=[], help="TARGET=REASON: measurement incomplete, floor not checked")
    a = ap.parse_args(argv)
    llvm = {}
    for spec in a.llvm:
        package, _, path = spec.partition("=")
        llvm[package] = Path(path).read_text()
    xccov = [Path(p).read_text() for p in a.xccov]
    floors = read_floors(a.floors.read_text(), a.tier) if a.floors else dict(TIER_FLOORS.get(a.tier, {}))
    partial = dict(spec.split("=", 1) for spec in a.partial)
    summary, breaches, packages_line = report(collect(llvm, xccov), floors, a.tier, a.out, partial)
    for line in summary + breaches:
        print(line)
    print(f"coverage: packages {packages_line}")
    return 1 if any(not b.startswith("coverage: PARTIAL ") for b in breaches) else 0


if __name__ == "__main__":
    sys.exit(main())
