#!/bin/zsh
# verify.sh — run scripts/run-tests-vm.sh with its output kept out of the caller's context.
#
# The VM run streams every step's full log (thousands of lines). Agents call this instead: the full output goes to
# build/vm-tests/<run-id>/run.out, and only a short report is printed — a few lines on success, the filtered
# failure lines on failure. The exit code is run-tests-vm.sh's (0 pass, 1 fail, 2 usage, 3 infra).
#
# Usage: scripts/verify.sh [--expect NAME[,NAME…]]… [--expect-fail NAME[,NAME…]]… [run-tests-vm.sh options]
#   --expect NAMES  test function names (comma-separated, repeatable) that must appear in the logs as passed;
#                   a missing or failed one makes the run fail (exit 1). Use it for the tests a change adds.
#                   XCTest names (RoadieTests, RoadieUITests) work with or without their `test` prefix:
#                   `playsTheFixtureLibrary` and `testPlaysTheFixtureLibrary` both match.
#   --expect-fail NAMES  test function names (comma-separated, repeatable) that must appear in the logs as FAILED.
#                   The run then passes (exit 0) only if each named test failed and no other test or step did.
#                   Bug-fix recipe: write the regression test first, run --expect-fail it (proves it fails before the
#                   fix), then fix the code and run --expect it. A name can't be in both lists (exit 2). Build
#                   failures, SKIP, AUDIO and INFRA are unchanged: a test that doesn't compile is not "failing".
#   Everything else is passed to scripts/run-tests-vm.sh unchanged (--head, --full, --build-only, --launch, …).
#
# An infrastructure failure (exit 3: the guest was lost or didn't boot) is retried once automatically.
#
# Output:
#   pass  ==> VERIFY PASS …, the TIER / AUDIO / BUILD-ONLY lines, a test total, the --expect result (≤ 8 lines)
#   --coverage runs (#0212) add the COVERAGE line (pass and fail); a floor breach fails with the `coverage: FLOOR …`
#         lines, and an App number without a complete UI run shows as `coverage: PARTIAL App …` (floor not checked).
#   --ui runs (#0200) add the UI summary line on pass; on a failed ui-tests/app-unit-tests step, a `screenshots:` line
#         per failed test (results/ui/attachments/<testName>/) and the xcresult path; a timed-out ui-tests step (exit
#         124) has a TIMEOUT line: the elapsed time against the step's limit and the test that was running.
#   fail  ==> VERIFY FAIL …, the FAIL/BUILD/ERRORS/INFRA/TIMEOUT/COVERAGE/AUDIO lines from summary.txt, then from each failed
#         step's log the failing tests (✘ lines with their ↳ details), crashes and XCTest failures; at most
#         MAX_LINES (60) lines. Also written to build/vm-tests/<run-id>/failure.txt.
#   The last line names the results directory, for a human; agents should not read the logs.
#
#   scripts/verify.sh --report build/vm-tests/<run-id> [--expect …] [--expect-fail …] [--exit N]
#     rebuilds the report from a finished run without running anything (exit N defaults to the one in summary.txt).

set -uo pipefail

REPO=${0:A:h:h}
RUNNER=${VERIFY_RUNNER:-$REPO/scripts/run-tests-vm.sh}  # override only to test this script
MAX_LINES=${VERIFY_MAX_LINES:-60}
expect=()
expect_fail=()
args=()
REPORT_DIR=""
REPORT_RC=""
while (( $# )); do
  case $1 in
    --expect) (( $# >= 2 )) || { print -u2 "verify.sh: --expect needs NAMES"; exit 2; }
              expect+=(${(s:,:)2}); shift 2 ;;
    --expect-fail) (( $# >= 2 )) || { print -u2 "verify.sh: --expect-fail needs NAMES"; exit 2; }
              expect_fail+=(${(s:,:)2}); shift 2 ;;
    --expect-fail=*) expect_fail+=(${(s:,:)${1#--expect-fail=}}); shift ;;
    --expect=*) expect+=(${(s:,:)${1#--expect=}}); shift ;;
    --report) REPORT_DIR=${2:A}; shift 2 ;;
    --exit) REPORT_RC=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

expect=(${expect%%\(*}); expect_fail=(${expect_fail%%\(*})
both=(${expect:*expect_fail})
if (( ${#both} )); then
  print -u2 "verify.sh: ${(j:, :)both} in both --expect and --expect-fail"; exit 2
fi

# Colour codes and the OSC 8 hyperlinks swiftc wraps diagnostic group names in.
strip() { perl -pe 's/\e\]8;;.*?\e\\//g; s/\e\[[0-9;]*m//g'; }

run_once() {
  OUT=$(mktemp "$REPO/build/verify-out.XXXXXX")
  "$RUNNER" "${args[@]}" >"$OUT" 2>&1
  RC=$?
  RESULTS=$(strip <"$OUT" | sed -n 's/^==> Logs: //p' | tail -1)
  if [[ -n "$RESULTS" && -d "$RESULTS" ]]; then mv "$OUT" "$RESULTS/run.out"; OUT="$RESULTS/run.out"; fi
}

if [[ -n "$REPORT_DIR" ]]; then
  RESULTS=$REPORT_DIR
  OUT="$RESULTS/run.out"
  RC=${REPORT_RC:-$(sed -n 's/^==> Cleaning up (exit \([0-9]*\)).*/\1/p' "$RESULTS/summary.txt" 2>/dev/null | tail -1)}
  RC=${RC:-1}
else
  mkdir -p "$REPO/build"
  run_once
  if (( RC == 3 )); then
    print "==> VERIFY  INFRA (exit 3) in ${RESULTS:t}; retrying once"
    run_once
  fi
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
    # XCTest methods carry a `test` prefix: `freshDefaults` also matches `testFreshDefaults` (#0193).
    xc_name="test${(U)name[1]}${name[2,-1]}"
    if ! cat "${step_logs[@]}" 2>/dev/null | strip | grep -E "^✔ Test ${name}\(.*passed|Test Case '.*[ .](${name}|${xc_name})\]' passed" >/dev/null; then
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

# --expect-fail: each name must have "✘ Test name(…" (swift-testing) or "Test Case '…name]' failed" (XCTest), and the
# only failures in the run must be those tests: then the run's exit 1 becomes 0.
expect_fail_report=""
if (( ${#expect_fail} && RC != 2 && RC != 3 )); then
  logtext=$(cat "${step_logs[@]}" 2>/dev/null | strip)
  wrong=()
  for name in $expect_fail; do
    print -r -- "$logtext" | grep -E "^✘ Test ${name}\(|Test Case '.*[ .]${name}\]' failed" >/dev/null || wrong+=("$name")
  done
  failed=(${(u)${(f)"$(print -r -- "$logtext" | perl -ne 'print "$1\n" if /^✘ Test ([A-Za-z0-9_]+)\(/ || /Test Case .*[ .]([A-Za-z0-9_]+)\]. failed/')"}})
  others=(${failed:|expect_fail})
  # Steps that failed without one of the expected tests failing in them (crash, build, SKIP, AUDIO) count as other.
  for f in "${step_logs[@]}"; do
    step=${f:t:r}
    grep -q "^==> FAIL  $step " "$SUMMARY" 2>/dev/null || continue
    hit=0
    for name in $expect_fail; do
      strip <"$f" | grep -E "^✘ Test ${name}\(|Test Case '.*[ .]${name}\]' failed" >/dev/null && hit=1
    done
    (( hit )) || others+=("step $step")
    # A crash in the same step can stop other tests after the expected one has already failed.
    (( hit )) && strip <"$f" | grep -qE 'Fatal error|unexpected signal|Precondition failed|Assertion failed' \
      && others+=("crash in step $step")
  done
  grep -qE '^==> (BUILD|SKIP|INFRA)  |^==> AUDIO  host' "$SUMMARY" 2>/dev/null && others+=("build/skip/audio in summary")
  if (( ${#wrong} == 0 && ${#others} == 0 && (RC == 0 || RC == 1) )); then
    expect_fail_report="==> EXPECT-FAIL  all ${#expect_fail} expected test(s) failed as required"
    [[ ${expect_report:-} == *"did not pass"* ]] || RC=0
  else
    expect_fail_report=""
    (( ${#wrong} )) && expect_fail_report="==> EXPECT-FAIL  ${#wrong} of ${#expect_fail} expected test(s) passed or never ran: ${(j:, :)wrong}"
    (( ${#others} )) && expect_fail_report+="${expect_fail_report:+
}==> EXPECT-FAIL  other tests failed too: ${(j:, :)others}"
    RC=1
  fi
fi

if (( RC == 0 )); then
  # swift-testing's "Test run with N tests" per package, plus XCTest's (RoadieTests, #0193): XCTest prints
  # "Executed N tests, with M failures" per suite and again for the bundle and "All tests", so each log counts only its last.
  # `swift test` also prints an empty XCTest run ("Executed 0 tests") per package; those aren't test runs.
  total=$( {
    cat "${step_logs[@]}" 2>/dev/null | strip | grep -oE 'Test run with [0-9]+ tests' | awk '{print $4}'
    for f in "${step_logs[@]}"; do strip <"$f" 2>/dev/null | grep -oE 'Executed [0-9]+ tests?, with' | tail -1 | awk '$2 > 0 {print $2}'; done
  } | awk '{s+=$1; n++} END {if (n) print s " tests in " n " test runs"}')
  print "==> VERIFY  PASS (exit 0) ${RESULTS:t}: $(grep -c '^==> PASS' "$SUMMARY" 2>/dev/null) steps passed${total:+, $total}"
  # #0200: run-tests-vm.sh retries a failed UI test once (-retry-tests-on-failure -test-iterations 2); a test with
  # both a failed and a passed "Test Case" line passed only on retry, so the UI line says so instead of hiding the flake.
  retried=()
  if [[ -f "$RESULTS/ui-tests.log" ]]; then
    uilog=$(strip <"$RESULTS/ui-tests.log")
    for t in ${(u)${(f)"$(print -r -- "$uilog" | perl -ne "print \"\$1\\n\" if /Test Case '-\\[\\S+ (\\w+)\\]' failed/")"}}; do
      print -r -- "$uilog" | grep -qE "Test Case '-\[[^ ]+ ${t}\]' passed" && retried+=("$t")
    done
  fi
  retry_note=""
  (( ${#retried} )) && retry_note=" (${#retried} passed on retry: ${(j:, :)retried})"
  grep -E '^==> (TIER|UI|COVERAGE|AUDIO|BUILD-ONLY|SKIP)' "$SUMMARY" 2>/dev/null \
    | while IFS= read -r l; do [[ $l == "==> UI  "[0-9]* ]] && l+=$retry_note; print -r -- "$l"; done
  [[ -n "$expect_report" ]] && print -r -- "$expect_report"
  [[ -n "$expect_fail_report" ]] && print -r -- "$expect_fail_report"
  [[ -f "$RESULTS/release/Roadie.app.zip" ]] && print "==> RELEASE  $RESULTS/release/Roadie.app.zip build $(cat "$RESULTS/release/build.txt" 2>/dev/null || print unknown) (scripts/make-dmg.sh packages it)"
  print "==> Results: $RESULTS"
  exit 0
fi

# Failure: build the report, cap it, save it next to the logs.
report=$(
  print "==> VERIFY  FAIL (exit $RC)${RESULTS:+ ${RESULTS:t}}"
  if [[ -f "$SUMMARY" ]]; then
    # The summary's own failure lines, with the indented compiler-error block that follows ERRORS.
    awk '/^==> (FAIL|BUILD|INFRA|TIMEOUT|COVERAGE|AUDIO)/ {print; next}
         /^==> ERRORS  no file:line:col/ {e=0; next}
         /^==> ERRORS/ {print; e=1; next}
         /^==> / {e=0}
         e && /^    / && !/Build complete!|BUILD SUCCEEDED/ {print}' "$SUMMARY" | strip
  else
    # Usage error or preflight failure: no summary was written; the tail of the output says why.
    strip <"$OUT" | grep -v '^[[:space:]]*$' | tail -15
  fi
  [[ -n "$expect_report" ]] && print -r -- "$expect_report"
  [[ -n "$expect_fail_report" ]] && print -r -- "$expect_fail_report"
  for f in "${step_logs[@]}"; do
    step=${f:t:r}
    grep -q "^==> FAIL  $step " "$SUMMARY" 2>/dev/null || continue
    if [[ $step == *-build ]]; then
      # file:line:col errors are already in the ERRORS block; anything else (macro expansions, linker, SwiftPM
      # errors) is extracted here: each diagnostic with up to 10 lines of its context.
      grep -q '^==> ERRORS  no file:line:col' "$SUMMARY" 2>/dev/null || continue
      lines=$(strip <"$f" | awk '
        /Failed frontend command|^[[:space:]]*$/ {n=0; next}
        /error: / && !/SwiftCompile .* failed with a nonzero exit code|^error: Build failed|^error: fatalError/ {print; n=10; next}
        n > 0 {print; n--}' | awk '!seen[$0]++')
      if [[ -n "$lines" ]]; then
        print "==> $step errors:"
        print -r -- "$lines" | sed 's/^/    /'
      else
        print "==> $step: no error lines found; last lines of its log:"
        strip <"$f" | grep -vE '^[[:space:]]*$|Failed frontend command' | tail -10 | sed 's/^/    /'
      fi
      continue
    fi
    if [[ $step == coverage-report ]]; then
      # #0212: floor breaches (or why nothing was measured), never test-failure lines.
      lines=$(strip <"$f" | grep -E '^coverage: (FLOOR|PARTIAL|NO DATA|MISSING|nothing|llvm-cov|xccov)' | awk '!seen[$0]++')
      print "==> coverage-report failures:"
      if [[ -n "$lines" ]]; then print -r -- "$lines" | sed 's/^/    /'
      else strip <"$f" | grep -v '^[[:space:]]*$' | tail -10 | sed 's/^/    /'; fi
      continue
    fi
    lines=$(strip <"$f" | grep -E '^✘ Test .*(recorded an issue|failed)|^↳ |Fatal error|unexpected signal|error: -\[|Test Case .* failed|: error: |Assertion failed|Precondition failed' \
      | grep -vE '^↳ (Testing Library Version|Target Platform)' | awk '!seen[$0]++')
    if [[ -n "$lines" ]]; then
      print "==> $step failures:"
      print -r -- "$lines" | sed 's/^/    /'
      # Warnings from the files the step's errors name (dedup, at most 5).
      files=(${(u)${(f)"$(print -r -- "$lines" | perl -ne 'print "$1\n" if m{([^\s:/]+\.swift):\d+(:\d+)?: error: }')"}})
      if (( ${#files} )); then
        warns=$(strip <"$f" | grep -E ': warning: ' | grep -F "${(F)files}" | awk '!seen[$0]++' | head -5)
        [[ -n "$warns" ]] && print -r -- "$warns" | sed 's/^/    /'
      fi
    else
      print "==> $step: no test-failure lines; last lines of its log:"
      strip <"$f" | grep -v '^[[:space:]]*$' | tail -10 | sed 's/^/    /'
    fi
    if [[ $step == ui-tests ]]; then
      attach="$RESULTS/ui/attachments"
      for t in ${(u)${(f)"$(strip <"$f" | perl -ne "print \"\$1\\n\" if /Test Case '-\\[\\S+ (\\w+)\\]' failed/")"}}; do
        if [[ -d "$attach/$t" ]]; then print "    screenshots: $attach/$t/"
        else print "    screenshots: none exported ($t)"; fi
      done
      [[ -d "$RESULTS/ui/UITests.xcresult" ]] && print "    xcresult: $RESULTS/ui/UITests.xcresult"
    fi
  done
)
report=$(print -r -- "$report" | cut -c1-300)
total_lines=$(print -r -- "$report" | wc -l | tr -d ' ')
print -r -- "$report" | head -$MAX_LINES
(( total_lines > MAX_LINES )) && print "==> (report cut at $MAX_LINES of $total_lines lines; full report in failure.txt)"
if [[ -n "$RESULTS" && -d "$RESULTS" ]]; then
  print -r -- "$report" >"$RESULTS/failure.txt"
  print "==> Results: $RESULTS"
fi
exit $RC
