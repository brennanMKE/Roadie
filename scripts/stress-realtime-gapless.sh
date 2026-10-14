#!/bin/zsh
# stress-realtime-gapless.sh — runs IN THE TART GUEST (see scripts/run-tests-vm.sh --stress).
# Repeats the real-time gapless test N times against the already-built PlayerKit test binary,
# optionally with CPU hogs running (--load), and prints "stress: <fails>/<N> failed".
# Usage: scripts/stress-realtime-gapless.sh N [LOAD]   (LOAD=1 starts four `yes` hogs)

N=${1:?iterations}
LOAD=${2:-0}
RESULTS=${RESULTS:-$HOME/results}
mkdir -p "$RESULTS"

cleanup() { pkill -x yes 2>/dev/null; true }
trap cleanup EXIT

if (( LOAD )); then
  for _ in 1 2 3 4; do yes > /dev/null & done
  print -- "stress: 4 CPU hogs started"
fi

fails=0
for i in {1..$N}; do
  print -- "--- stress iteration $i/$N"
  if ! AUDIOCORE_REALTIME=1 swift test --package-path Packages/PlayerKit --skip-build \
      --filter 'MixedFormatRealtimeTests/mixedFormatsAdvanceWithoutGapRealtime' 2>&1 | tee "$RESULTS/stress-iter.tmp" \
      | grep -E '\[#0055\]|Test run with|✘|✔ Test mixed'; then
    :
  fi
  grep -q '✘' "$RESULTS/stress-iter.tmp" && { fails=$((fails + 1)); print -- "iteration $i FAILED"; }
  grep -q 'Test run with 1 test' "$RESULTS/stress-iter.tmp" || print -- "iteration $i: test did not run (check filter)"
done
rm -f "$RESULTS/stress-iter.tmp"

uptime
/usr/bin/log show --last 15m --predicate 'process == "coreaudiod" OR subsystem == "com.apple.coreaudio"' \
  > "$RESULTS/guest-coreaudio.log" 2>&1 || true
print -- "stress: $fails/$N failed"
(( fails == 0 ))
