#!/bin/zsh
# coverage-report.sh — per-target line coverage of a --coverage VM run (#0212). Runs in the guest, from the repo root.
#
# Usage: scripts/coverage-report.sh [--app-partial REASON] <out> [xcresult…]
#   --app-partial: the UI tests didn't run or didn't finish (run-tests-vm.sh passes why), so the App number is
#        partial: it is reported as `coverage: PARTIAL App …` and its floor isn't checked.
#   Packages: llvm-cov report of each package's test binaries (one .xctest per test target) against its default.profdata (swift test --enable-code-coverage).
#   App: xccov reports of the given xcresult bundles (default: build/DerivedData/Logs/Test/*.xcresult and
#        <out>/../ui/UITests.xcresult), max per file, App/ only.
#   Writes <out>/report.md, lowest.txt, summary.txt, packages.txt (coverage_report.py does the math).
#   Exit 1 when a target is under its floor in scripts/coverage-floors.tsv (`coverage: FLOOR …`), a floored target has no
#   files measured (`coverage: MISSING …`), or nothing was measured.

set -uo pipefail
APP_PARTIAL=""
if [[ ${1:-} == --app-partial ]]; then APP_PARTIAL=${2:?--app-partial needs a reason}; shift 2; fi
OUT=${1:?usage: coverage-report.sh [--app-partial REASON] <out> [xcresult…]}; shift
mkdir -p "$OUT"
OUT=${OUT:A}
REPO=${0:A:h:h}
TIER=$(cat "$OUT/../tier.txt" 2>/dev/null || print fast)
IGNORE='Tests/|\.build/|/checkouts/'
args=(--out "$OUT" --floors "$REPO/scripts/coverage-floors.tsv" --tier "$TIER")
[[ -n "$APP_PARTIAL" ]] && args+=(--partial "App=$APP_PARTIAL")
measured=0

for pkg in SkinKit PlayerKit; do
  dir="$REPO/Packages/$pkg"
  codecov=$(swift test --skip-build --enable-code-coverage --show-codecov-path --package-path "$dir" 2>/dev/null | tail -1)
  prof="${codecov:h}/default.profdata"
  bin_dir=$(swift build --show-bin-path --package-path "$dir" 2>/dev/null | tail -1)
  # SwiftPM builds one <TestTarget>.xctest per test target (not one <Pkg>PackageTests.xctest), and each holds only the
  # targets its tests import: hand llvm-cov all of them (the first as the binary, the rest as -object) so every target counts.
  bins=("$bin_dir"/*.xctest/Contents/MacOS/*(N.))
  if [[ ! -f "$prof" || ${#bins} -eq 0 ]]; then
    print -r -- "coverage: NO DATA $pkg (profdata '$prof', no test binaries in '$bin_dir'): was it built and tested with --enable-code-coverage?"
    continue
  fi
  objects=("${bins[1]}"); for b in "${(@)bins[2,-1]}"; do objects+=(-object "$b"); done
  print -r -- "coverage: $pkg ${#bins} test binaries, profdata $prof"
  xcrun llvm-cov report "${objects[@]}" -instr-profile "$prof" -ignore-filename-regex "$IGNORE" >"$OUT/$pkg.llvm-cov.txt" \
    || { print -r -- "coverage: llvm-cov failed for $pkg"; continue; }
  args+=(--llvm "$pkg=$OUT/$pkg.llvm-cov.txt"); measured=1
done

bundles=("$@")
if (( ! ${#bundles} )); then
  bundles=("$REPO"/build/DerivedData/Logs/Test/*.xcresult(N))
  [[ -d "${OUT:h}/ui/UITests.xcresult" ]] && bundles+=("${OUT:h}/ui/UITests.xcresult")
fi
i=0
for b in $bundles; do
  (( i++ ))
  if xcrun xccov view --report --json "$b" >"$OUT/app-$i.xccov.json" 2>/dev/null; then
    args+=(--xccov "$OUT/app-$i.xccov.json"); measured=1
  else
    print -r -- "coverage: xccov failed for ${b:t} (no coverage in it?)"; rm -f "$OUT/app-$i.xccov.json"
  fi
done

(( measured )) || { print -r -- "coverage: nothing measured"; exit 1; }
python3 -I "$REPO/scripts/coverage_report.py" "${args[@]}"
