#!/bin/zsh
# verify.sh — run scripts/run-tests-vm.sh with its output kept out of the caller's context.
#
# The VM run streams every step's full log (thousands of lines). Agents call this instead: the full output goes to
# build/vm-tests/<run-id>/run.out, and only a short report is printed — a few lines on success, the filtered
# failure lines on failure. The exit code is run-tests-vm.sh's (0 pass, 1 fail, 2 usage, 3 infra).
#
# Usage: scripts/verify.sh [--expect NAME[,NAME…]]… [run-tests-vm.sh options]
#   --expect NAMES  test function names (comma-separated, repeatable) that must appear in the logs as passed;
#                   a missing or failed one makes the run fail (exit 1). Use it for the tests a change adds.
#   Everything else is passed to scripts/run-tests-vm.sh unchanged (--head, --full, --build-only, --launch, …).
#
# An infrastructure failure (exit 3: the guest was lost or didn't boot) is retried once automatically.
#
# Output:
#   pass  ==> VERIFY PASS …, the TIER / AUDIO / BUILD-ONLY lines, a test total, the --expect result (≤ 8 lines)
#   fail  ==> VERIFY FAIL …, the FAIL/BUILD/ERRORS/INFRA/AUDIO lines from summary.txt, then from each failed
#         step's log the failing tests (✘ lines with their ↳ details), crashes and XCTest failures; at most
#         MAX_LINES (60) lines. Also written to build/vm-tests/<run-id>/failure.txt.
#   The last line names the results directory, for a human; agents should not read the logs.

set -uo pipefail

REPO=${0:A:h:h}
RUNNER=${VERIFY_RUNNER:-$REPO/scripts/run-tests-vm.sh}  # override only to test this script
MAX_LINES=${VERIFY_MAX_LINES:-60}
expect=()
args=()
while (( $# )); do
  case $1 in
    --expect) (( $# >= 2 )) || { print -u2 "verify.sh: --expect needs NAMES"; exit 2; }
              expect+=(${(s:,:)2}); shift 2 ;;
    --expect=*) expect+=(${(s:,:)${1#--expect=}}); shift ;;
    *) args+=("$1"); shift ;;
  esac
done

strip() { sed $'s/\e\\[[0-9;]*m//g'; }

run_once() {
  OUT=$(mktemp "$REPO/build/verify-out.XXXXXX")
  "$RUNNER" "${args[@]}" >"$OUT" 2>&1
  RC=$?
  RESULTS=$(strip <"$OUT" | sed -n 's/^==> Logs: //p' | tail -1)
  if [[ -n "$RESULTS" && -d "$RESULTS" ]]; then mv "$OUT" "$RESULTS/run.out"; OUT="$RESULTS/run.out"; fi
}

mkdir -p "$REPO/build"
run_once
if (( RC == 3 )); then
  print "==> VERIFY  INFRA (exit 3) in ${RESULTS:t}; retrying once"
  run_once
fi

SUMMARY="$RESULTS/summary.txt"
step_logs=()
[[ -n "$RESULTS" ]] && step_logs=("$RESULTS"/*.log(N))

# --expect: each name must have a "✔ Test name(…) passed" (swift-testing) or "Test Case '…name]' passed" (XCTest).
expect_report=""
if (( ${#expect} && RC != 2 )); then
  missing=()
  for name in $expect; do
    name=${name%%\(*}
    if ! cat "${step_logs[@]}" 2>/dev/null | strip | grep -E "^✔ Test ${name}\(.*passed|Test Case '.*[ .]${name}\]' passed" >/dev/null; then
      missing+=("$name")
    fi
  done
  if (( ${#missing} )); then
    expect_report="==> EXPECT  ${#missing} of ${#expect} expected test(s) did not pass or never ran: ${(j:, :)missing}"
    (( RC == 0 )) && RC=1
  else
    expect_report="==> EXPECT  all ${#expect} expected test(s) passed"
  fi
fi

if (( RC == 0 )); then
  total=$(cat "${step_logs[@]}" 2>/dev/null | strip | grep -oE 'Test run with [0-9]+ tests' | awk '{s+=$4; n++} END {if (n) print s " tests in " n " test runs"}')
  print "==> VERIFY  PASS (exit 0) ${RESULTS:t}: $(grep -c '^==> PASS' "$SUMMARY" 2>/dev/null) steps passed${total:+, $total}"
  grep -E '^==> (TIER|AUDIO|BUILD-ONLY|SKIP)' "$SUMMARY" 2>/dev/null
  [[ -n "$expect_report" ]] && print -r -- "$expect_report"
  print "==> Results: $RESULTS"
  exit 0
fi

# Failure: build the report, cap it, save it next to the logs.
report=$(
  print "==> VERIFY  FAIL (exit $RC)${RESULTS:+ ${RESULTS:t}}"
  if [[ -f "$SUMMARY" ]]; then
    # The summary's own failure lines, with the indented compiler-error block that follows ERRORS.
    awk '/^==> (FAIL|BUILD|INFRA|AUDIO)/ {print; next}
         /^==> ERRORS/ {print; e=1; next}
         /^==> / {e=0}
         e && /^    / && !/Build complete!|BUILD SUCCEEDED/ {print}' "$SUMMARY"
  else
    # Usage error or preflight failure: no summary was written; the tail of the output says why.
    strip <"$OUT" | grep -v '^[[:space:]]*$' | tail -15
  fi
  [[ -n "$expect_report" ]] && print -r -- "$expect_report"
  for f in "${step_logs[@]}"; do
    step=${f:t:r}
    grep -q "^==> FAIL  $step " "$SUMMARY" 2>/dev/null || continue
    [[ $step == *-build ]] && continue  # compiler errors are already in the ERRORS block
    lines=$(strip <"$f" | grep -E '^✘ Test .*(recorded an issue|failed)|^↳ |Fatal error|unexpected signal|error: -\[|Test Case .* failed|: error: |Assertion failed|Precondition failed' \
      | grep -vE '^↳ (Testing Library Version|Target Platform)' | awk '!seen[$0]++')
    if [[ -n "$lines" ]]; then
      print "==> $step failures:"
      print -r -- "$lines" | sed 's/^/    /'
    else
      print "==> $step: no test-failure lines; last lines of its log:"
      strip <"$f" | grep -v '^[[:space:]]*$' | tail -10 | sed 's/^/    /'
    fi
  done
)
total_lines=$(print -r -- "$report" | wc -l | tr -d ' ')
print -r -- "$report" | head -$MAX_LINES
(( total_lines > MAX_LINES )) && print "==> (report cut at $MAX_LINES of $total_lines lines; full report in failure.txt)"
if [[ -n "$RESULTS" && -d "$RESULTS" ]]; then
  print -r -- "$report" >"$RESULTS/failure.txt"
  print "==> Results: $RESULTS"
fi
exit $RC
