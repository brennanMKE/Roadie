#!/bin/zsh
# run-tests-vm.sh — build and test SkinAmp inside a disposable Tart VM.
#
# Tests and builds never run on the host; see docs/testing-in-vm.md. Each run
# clones the shared golden image (resolved by `tart-golden`, never hardcoded),
# boots it headless with audio cut off from the host (`--no-audio`) and the guest
# output muted, runs the checks, pulls the logs back to build/vm-tests/<run-id>/,
# and deletes the clone.
#
# Usage: scripts/run-tests-vm.sh [--head] [--launch]
#   --head    test the last commit (git archive HEAD) instead of the working tree
#   --launch  also launch the built app in the guest for a few seconds (smoke test)
#
# In the guest, in order:
#   1. swift test --package-path Packages/SkinKit
#   2. swift test --package-path Packages/PlayerKit   (AUDIOCORE_REALTIME=1, muted)
#   3. xcodebuild ... build                             (project generated on the host)
#   4. optional: launch SkinAmp.app, check it stays up, quit it
# The script exits non-zero if any step fails, and also if the host's coreaudiod
# logged "Starting IO" during the run, i.e. if anything reached a speaker.

set -euo pipefail

USE_HEAD=0
LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --head) USE_HEAD=1 ;;
    --launch) LAUNCH=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CLONE="skinamp-test-$RUN_ID"
EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/skinamp-test-export.XXXXXX")"
RESULTS_DIR="$REPO/build/vm-tests/$RUN_ID"
GUEST_SRC="/Users/admin/src"
GUEST_RESULTS="/Users/admin/results"
BOOT_TIMEOUT_SECS=120
# Keep in sync with the golden image's memory (`tart set --memory`).
GUEST_MEM_MB=12288
LEASE_ID=""
MEMORY_REQUEST_ID=""
START_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

MEMORY_LIB="$HOME/Developer/Homelab/protocols/memory-signal/lib/memory-signal.sh"
[[ -f "$MEMORY_LIB" ]] && source "$MEMORY_LIB"

cleanup() {
  local rc=$?
  trap - EXIT
  log "Cleaning up (exit $rc)"
  # Give the Tart slot back first so a waiting session starts sooner.
  [[ -n "$LEASE_ID" ]] && { tart-lease release --id "$LEASE_ID" 2>/dev/null || true; }
  if [[ -n "$MEMORY_REQUEST_ID" ]] && typeset -f memory_release >/dev/null; then
    memory_release 2>/dev/null || true
  fi
  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  rm -rf "$EXPORT"
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------

command -v tart >/dev/null || fail "Tart is not installed (brew install cirruslabs/cli/tart)"
command -v tart-golden >/dev/null || fail "tart-golden not on PATH -- see ~/Developer/Homelab/protocols/tart-golden/PROTOCOL.md"
command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"
GOLDEN="$(tart-golden require --xcode 27.0)"

free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 20 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / -- need at least 20 GiB"

need_bytes=$(( (GUEST_MEM_MB + 4096) * 1024 * 1024 ))
if typeset -f memory_available_bytes >/dev/null; then
  avail=$(memory_available_bytes)
  if (( avail < need_bytes )); then
    log "Host memory short ($(( avail / 1073741824 )) of $(( need_bytes / 1073741824 )) GiB) -- asking the memory-signal observer"
    set +e
    memory_request "$need_bytes" "skinamp-run-tests-vm" "Tart VM test run needs guest RAM plus headroom" 120
    rc=$?
    set -e
    (( rc == 0 )) || fail "Memory request not fulfilled (rc=$rc); free memory and retry"
  fi
fi

# A SIGKILL skips the trap, so sweep clones left by earlier runs. Only names
# shaped exactly like this script's run IDs are touched; the golden can't match.
for old in $(tart list | awk '$2 ~ /^skinamp-test-[0-9]{8}-[0-9]{6}-[0-9]+$/ { print $2 }'); do
  [[ "$old" == "$CLONE" || "$old" == "$GOLDEN" ]] && continue
  log "Sweeping stale clone: $old"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done

# --- Export a snapshot -----------------------------------------------------
# Working tree by default (tracked plus untracked-but-not-ignored files), so a
# change can be verified before it is committed. Never shared read-write.

mkdir -p "$EXPORT/src"
if (( USE_HEAD )); then
  log "Exporting HEAD ($(git -C "$REPO" rev-parse --short HEAD))"
  git -C "$REPO" archive HEAD | tar -x -C "$EXPORT/src"
else
  log "Exporting the working tree"
  # Skip files deleted in the working tree (macOS openrsync has no --ignore-missing-args).
  ( cd "$REPO" && git ls-files -z -co --exclude-standard \
      | while IFS= read -r -d '' f; do [[ -e "$f" ]] && print -rN -- "$f"; done ) \
    | rsync -a --from0 --files-from=- "$REPO/" "$EXPORT/src/"
fi
# SkinAmp.xcodeproj is gitignored; generate it here so the guest needs no XcodeGen.
xcodegen generate --quiet --spec "$EXPORT/src/project.yml"

# --- Clone and boot --------------------------------------------------------

if command -v tart-lease >/dev/null; then
  LEASE_ID=$(tart-lease acquire --label skinamp --pid $$)
else
  log "WARNING: tart-lease not on PATH -- running without admission control"
fi

log "Cloning $GOLDEN -> $CLONE"
tart clone "$GOLDEN" "$CLONE"
log "Booting headless, no audio device, export mounted read-only"
tart run "$CLONE" --no-graphics --no-audio --dir=run:"$EXPORT":ro >"$EXPORT/tart-run.log" 2>&1 &
boot_deadline=$(( SECONDS + BOOT_TIMEOUT_SECS ))
until tart exec "$CLONE" true >/dev/null 2>&1; do
  (( SECONDS < boot_deadline )) || fail "Guest not reachable within ${BOOT_TIMEOUT_SECS}s (see $EXPORT/tart-run.log)"
  sleep 3
done
log "Guest reachable"

gx() { tart exec "$CLONE" /bin/zsh -lc "$1"; }

gx "rm -rf $GUEST_SRC $GUEST_RESULTS && mkdir -p $GUEST_RESULTS && cp -R '/Volumes/My Shared Files/run/src' $GUEST_SRC"
# The guest still has a virtual sound device; --no-audio only cuts its path to the
# host. Mute it as well, and record the device list and mute state as evidence.
gx "osascript -e 'set volume output volume 0' -e 'set volume with output muted' >/dev/null 2>&1 || true"
gx "{ system_profiler SPAudioDataType; print -- '--- output volume settings:'; osascript -e 'get volume settings'; } > $GUEST_RESULTS/audio-devices.txt 2>&1 || true"

# --- Steps -----------------------------------------------------------------
# `set -o pipefail` inside the guest shell: without it the status is tee's.

typeset -A step_rc
run_step() {
  local name=$1 cmd=$2
  log "Guest: $name"
  set +e
  gx "set -o pipefail; cd $GUEST_SRC && { $cmd; } 2>&1 | tee $GUEST_RESULTS/$name.log"
  step_rc[$name]=$?
  set -e
}

run_step skinkit-tests   "swift test --package-path Packages/SkinKit"
# The real-time tests run here too: the guest's virtual output device has no path to
# the host (--no-audio), the guest is muted, and the tests mute their own mixer.
run_step playerkit-tests "AUDIOCORE_REALTIME=1 swift test --package-path Packages/PlayerKit"
run_step app-build       "xcodebuild -project SkinAmp.xcodeproj -scheme SkinAmp -configuration Debug -derivedDataPath build/DerivedData build"
if (( LAUNCH )); then
  run_step app-launch "open build/DerivedData/Build/Products/Debug/SkinAmp.app && sleep 5 && pgrep -x SkinAmp && osascript -e 'quit app \"SkinAmp\"' && sleep 1 && ! pgrep -x SkinAmp"
fi

# --- Results back ----------------------------------------------------------

mkdir -p "$RESULTS_DIR"
gx "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$RESULTS_DIR"

# --- Host audio check ------------------------------------------------------
# With --no-audio the guest has no path to the host's speakers; prove it.

io_events=$(/usr/bin/log show --start "$START_STAMP" \
  --predicate 'process == "coreaudiod" AND eventMessage CONTAINS "Starting IO"' 2>/dev/null \
  | grep -vc '^Timestamp' || true)

print ""
overall=0
for name in ${(k)step_rc}; do
  if (( step_rc[$name] == 0 )); then log "PASS  $name"; else log "FAIL  $name (exit ${step_rc[$name]})"; overall=1; fi
done
grep -hE 'Test run with|TEST (SUCCEEDED|FAILED)|BUILD (SUCCEEDED|FAILED)' "$RESULTS_DIR"/*.log 2>/dev/null | sed 's/^/    /' || true
if (( io_events > 0 )); then
  log "AUDIO  host coreaudiod logged $io_events 'Starting IO' event(s) since $START_STAMP -- something reached a speaker (could be another app)"
  overall=1
else
  log "AUDIO  silent: no host 'Starting IO' events during the run"
fi
log "Logs: $RESULTS_DIR"
exit $overall
