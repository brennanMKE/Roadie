#!/bin/zsh
# run-skin-corpus.sh — runs IN THE TART GUEST (see scripts/run-tests-vm.sh --corpus). Issue #0038.
# Builds skintool in release, then runs `skintool corpus` over a folder of skins, restarting it with --resume
# after a crash, hang (exit 124) or memory blow-up (exit 125). Every skin ends with exactly one status in
# <out-dir>/results.jsonl. Prints "corpus: <unique> unique of <files> files, <restarts> restarts, ...".
# Usage: scripts/run-skin-corpus.sh <corpus-dir> <out-dir> [extra skintool corpus args, e.g. --sample 1000]
# Env: CORPUS_IN_PLACE=1 if <corpus-dir> is the read-only share rather than a copy; COMMIT_FILE=<file with the commit>.

set -u
CORPUS=${1:?corpus dir}
OUT=${2:?out dir}
shift 2
mkdir -p "$OUT"

swift build -c release --package-path Packages/SkinKit --product skintool || { print -r -- "corpus: release build failed"; exit 1 }
BIN="$(swift build -c release --package-path Packages/SkinKit --show-bin-path)/skintool"

COMMIT=$(cat "${COMMIT_FILE:-$HOME/results/commit.txt}" 2>/dev/null || print unknown)
{
  print -r -- "{"
  print -r -- "  \"macOS\": \"$(sw_vers -productVersion)\","
  print -r -- "  \"xcode\": \"$(xcodebuild -version | head -1)\","
  print -r -- "  \"cpus\": \"$(sysctl -n hw.ncpu)\","
  print -r -- "  \"memory\": \"$(( $(sysctl -n hw.memsize) / 1073741824 )) GiB\","
  print -r -- "  \"commit\": \"$COMMIT\","
  print -r -- "  \"corpus read\": \"$([[ ${CORPUS_IN_PLACE:-0} == 1 ]] && print in place from a read-only share || print copied to the guest disk)\","
  print -r -- "  \"started\": \"$(date '+%Y-%m-%d %H:%M:%S')\","
  print -r -- "  \"run\": \"${RUN_ID:-unknown}\""
  print -r -- "}"
} > "$OUT/env.json"

: > "$OUT/corpus-run.log"
: > "$OUT/corpus-stderr.log"
restarts=0
while true; do
  # stderr (ImageIO and CoreGraphics complaints about bad BMPs) goes to its own log, not the step output.
  /usr/bin/time -l "$BIN" corpus "$CORPUS" --out "$OUT" --resume "$@" 2>>"$OUT/corpus-stderr.log" | tee -a "$OUT/corpus-run.log"
  rc=${pipestatus[1]}
  if (( rc == 0 )); then break; fi
  if (( rc == 124 || rc == 125 || rc >= 128 )); then
    sleep 2   # let ReportCrash finish writing the .ips
    restarts=$(( restarts + 1 ))
    print -r -- "corpus: restart $restarts after exit $rc"
    if (( restarts > 1000 )); then print -r -- "corpus: more than 1000 restarts, giving up"; exit 1; fi
    continue
  fi
  print -r -- "corpus: skintool exited with $rc"
  exit 1
done

mkdir -p "$OUT/crashes"
cp ~/Library/Logs/DiagnosticReports/skintool* "$OUT/crashes/" 2>/dev/null
# `time -l` blocks land in corpus-stderr.log; keep the peak footprint lines in the run log too.
grep -E 'maximum resident|peak memory footprint' "$OUT/corpus-stderr.log" >> "$OUT/corpus-run.log" 2>/dev/null

count() { grep -c "\"status\":\"$1\"" "$OUT/results.jsonl" 2>/dev/null || true }
unique=$(grep '"event":"result"' "$OUT/results.jsonl" | grep -vc '"status":"duplicate"')
files=$(grep -c '"event":"result"' "$OUT/results.jsonl")
print -r -- "corpus: $unique unique of $files files, $restarts restarts, $(count crashed) crashed, $(count timeout) timed out, $(count memory) over memory"
