#!/bin/zsh
# run-tests-vm.sh — build and test SkinAmp inside a disposable Tart VM.
#
# Tests and builds never run on the host; see docs/testing-in-vm.md. Each run
# clones the shared golden image (resolved by `tart-golden`, never hardcoded),
# boots it headless with audio cut off from the host (`--no-audio`) and the guest
# output muted, runs the checks, pulls the logs back to build/vm-tests/<run-id>/,
# and deletes the clone.
#
# Usage: scripts/run-tests-vm.sh [--head] [--launch] [--skins DIR [--references DIR]] [--stress N [--load]] [--corpus DIR [--corpus-sample N]] [--spike]
#   --head    test the last commit (git archive HEAD) instead of the working tree
#   --launch  also launch the built app in the guest for a few seconds (smoke test)
#   --skins DIR  copy DIR/*.wsz into the guest's Skins/; adds steps skintool and skintool-png, runs sampleSkinsAreOk
#   --references DIR  with --skins: copy DIR/*.png (scripts/fetch-webamp-references.sh output) into Skins/reference/
#                     and diff each render against them in skintool-png (numbers only, never gated)
#   --stress N  also repeat the real-time gapless test N times in the guest (step playerkit-stress)
#   --load      with --stress: run four CPU hogs in the guest during the loop
#   --corpus DIR  run every .wsz/.zip under DIR (any layout) through `skintool corpus` in the guest (#0038): shared read-only
#                 as a second virtio-fs share, copied to the guest disk, then steps corpus-run and corpus-report; the
#                 corpus never enters git or the export. Results in build/vm-tests/<run-id>/corpus/
#   --corpus-sample N  with --corpus: only a seeded sample of N unique skins (the fast loop; 1000 is the acceptance sample)
#   --spike  also build, test and smoke-launch the AirPlay routing spike harness (#0050): steps spike-tests, spike-build, spike-smoke;
#            the smoke launch constructs every engine and never plays
#
# In the guest, in order:
#   1. swift test --package-path Packages/SkinKit     (SKIN_SAMPLES_DIR=Skins with --skins)
#      skintool Skins/ (only with --skins; fails unless every skin is ok), then skintool --png into results/png/
#   2. swift test --package-path Packages/PlayerKit   (AUDIOCORE_REALTIME=1, muted)
#   3. xcodebuild ... build                             (project generated on the host)
#   4. scripts/check-info-plist.sh on the built app's Info.plist (networking keys, .wsz type)
#      scripts/check-entitlements.sh on the built app (Location entitlement, #0075)
#   5. scripts/check-quicklook.sh: register the Quick Look extensions, qlmanage -t / -p a generated skin (#0043)
#   6. optional: launch SkinAmp.app, check it stays up, quit it
# The script exits non-zero if any step fails, and also if the host's coreaudiod
# logged "Starting IO" during the run, i.e. if anything reached a speaker.

set -euo pipefail

USE_HEAD=0
LAUNCH=0
STRESS=0
LOAD=0
SPIKE=0
SKINS_DIR=""
REFS_DIR=""
CORPUS_DIR=""
CORPUS_SAMPLE=""
args=("$@")
while (( $#args )); do
  arg=$args[1]; shift args
  case "$arg" in
    --head) USE_HEAD=1 ;;
    --launch) LAUNCH=1 ;;
    --stress) STRESS=${args[1]:-}; shift args 2>/dev/null; [[ "$STRESS" == <1-> ]] || { print -r -- "--stress needs a positive count" >&2; exit 2 } ;;
    --load) LOAD=1 ;;
    --spike) SPIKE=1 ;;
    --skins) SKINS_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$SKINS_DIR" && -d "$SKINS_DIR" ]] || { print -r -- "--skins needs a directory of .wsz files" >&2; exit 2 } ;;
    --references) REFS_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$REFS_DIR" && -d "$REFS_DIR" ]] || { print -r -- "--references needs a directory of reference PNGs" >&2; exit 2 } ;;
    --corpus) CORPUS_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$CORPUS_DIR" && -d "$CORPUS_DIR" ]] || { print -r -- "--corpus needs a directory of .wsz/.zip files" >&2; exit 2 } ;;
    --corpus-sample) CORPUS_SAMPLE=${args[1]:-}; shift args 2>/dev/null; [[ "$CORPUS_SAMPLE" == <1-> ]] || { print -r -- "--corpus-sample needs a positive count" >&2; exit 2 } ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $arg" >&2; exit 2 ;;
  esac
done

(( LOAD && ! STRESS )) && { print -r -- "--load needs --stress N" >&2; exit 2 }
[[ -n "$REFS_DIR" && -z "$SKINS_DIR" ]] && { print -r -- "--references needs --skins DIR" >&2; exit 2 }
[[ -n "$CORPUS_SAMPLE" && -z "$CORPUS_DIR" ]] && { print -r -- "--corpus-sample needs --corpus DIR" >&2; exit 2 }
if [[ -n "$CORPUS_DIR" ]]; then
  CORPUS_DIR="$(cd "$CORPUS_DIR" && pwd)"
  [[ -n "$(find "$CORPUS_DIR" -type f \( -iname '*.wsz' -o -iname '*.zip' \) -print -quit)" ]] \
    || { print -r -- "--corpus: no .wsz or .zip files under $CORPUS_DIR" >&2; exit 2 }
fi

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
# The AirPlay spike is its own XcodeGen project (#0050); generate it here too.
(( SPIKE )) && xcodegen generate --quiet --spec "$EXPORT/src/Spikes/AirPlaySpike/project.yml"
# Sample skins are never committed; with --skins they go into the throwaway export only.
if [[ -n "$SKINS_DIR" ]]; then
  mkdir -p "$EXPORT/src/Skins"
  cp "$SKINS_DIR"/*.wsz "$EXPORT/src/Skins/" || fail "No .wsz files in $SKINS_DIR"
  log "Copied $(ls "$EXPORT/src/Skins" | wc -l | tr -d ' ') skins from $SKINS_DIR into the export"
  # Reference screenshots were fetched on the host; the guest has no network.
  if [[ -n "$REFS_DIR" ]]; then
    mkdir -p "$EXPORT/src/Skins/reference"
    cp "$REFS_DIR"/*.png "$EXPORT/src/Skins/reference/" 2>/dev/null || true
    [[ -f "$REFS_DIR/manifest.tsv" ]] && cp "$REFS_DIR/manifest.tsv" "$EXPORT/src/Skins/reference/"
    log "Copied $(ls "$EXPORT/src/Skins/reference"/*.png 2>/dev/null | wc -l | tr -d ' ') reference PNGs from $REFS_DIR into the export"
  fi
fi

# --- Clone and boot --------------------------------------------------------

if command -v tart-lease >/dev/null; then
  LEASE_ID=$(tart-lease acquire --label skinamp --pid $$)
else
  log "WARNING: tart-lease not on PATH -- running without admission control"
fi

log "Cloning $GOLDEN -> $CLONE"
tart clone "$GOLDEN" "$CLONE"
log "Booting headless, no audio device, export mounted read-only"
# The corpus is a second, named, read-only share; the guest copies it to its own disk before anything is timed.
tart_dirs=(--dir=run:"$EXPORT":ro)
[[ -n "$CORPUS_DIR" ]] && tart_dirs+=(--dir=corpus:"$CORPUS_DIR":ro)
tart run "$CLONE" --no-graphics --no-audio "${tart_dirs[@]}" >"$EXPORT/tart-run.log" 2>&1 &
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

# The export has no .git; the corpus report wants the commit.
commit_text="$(git -C "$REPO" rev-parse --short HEAD)"
(( USE_HEAD )) || git -C "$REPO" diff --quiet HEAD -- 2>/dev/null || commit_text="$commit_text-dirty"
gx "print -r -- '$commit_text' > $GUEST_RESULTS/commit.txt"

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

if [[ -n "$SKINS_DIR" ]]; then
  run_step skinkit-tests "SKIN_SAMPLES_DIR=$GUEST_SRC/Skins swift test --package-path Packages/SkinKit"
  run_step skintool      "swift run --package-path Packages/SkinKit skintool -v Skins/"
  # Headless render of every skin to PNG (and, with --references, a diff against the Webamp screenshots).
  compare=""
  [[ -n "$REFS_DIR" ]] && compare="--compare $GUEST_SRC/Skins/reference"
  run_step skintool-png  "swift run --package-path Packages/SkinKit skintool --png $GUEST_RESULTS/png $compare Skins/"
else
  run_step skinkit-tests "swift test --package-path Packages/SkinKit"
fi
# The real-time tests run here too: the guest's virtual output device has no path to
# the host (--no-audio), the guest is muted, and the tests mute their own mixer.
run_step playerkit-tests "AUDIOCORE_REALTIME=1 swift test --package-path Packages/PlayerKit"
if (( STRESS )); then
  run_step playerkit-stress "scripts/stress-realtime-gapless.sh $STRESS $LOAD"
fi
run_step app-build       "xcodebuild -project SkinAmp.xcodeproj -scheme SkinAmp -configuration Debug -derivedDataPath build/DerivedData build"
run_step app-plist       "scripts/check-info-plist.sh build/DerivedData/Build/Products/Debug/SkinAmp.app/Contents/Info.plist"
run_step app-entitlements "scripts/check-entitlements.sh build/DerivedData/Build/Products/Debug/SkinAmp.app"
run_step app-quicklook   "scripts/check-quicklook.sh build/DerivedData/Build/Products/Debug/SkinAmp.app $GUEST_RESULTS/ql"
if (( LAUNCH )); then
  run_step app-launch "open build/DerivedData/Build/Products/Debug/SkinAmp.app && sleep 5 && pgrep -x SkinAmp && osascript -e 'quit app \"SkinAmp\"' && sleep 1 && ! pgrep -x SkinAmp"
fi

if (( SPIKE )); then
  # check-sdk.sh prints the long-form SDK findings into spike-tests.log first. The smoke launch must never play audio:
  # it constructs every engine and exits; open -W returns when the app quits, the grep is the real pass condition.
  run_step spike-tests "Spikes/AirPlaySpike/check-sdk.sh && swift test --package-path Spikes/AirPlaySpike/SpikeKit"
  run_step spike-build "xcodebuild -project Spikes/AirPlaySpike/AirPlaySpike.xcodeproj -scheme AirPlaySpike -configuration Debug -derivedDataPath build/DerivedData-spike build"
  run_step spike-smoke "mkdir -p $GUEST_RESULTS/spike && open -W -n build/DerivedData-spike/Build/Products/Debug/AirPlaySpike.app --args --smoke --log-dir $GUEST_RESULTS/spike && grep -q 'smoke: ok' $GUEST_RESULTS/spike/smoke.log && cat $GUEST_RESULTS/spike/smoke.log && ! pgrep -x AirPlaySpike"
fi

if [[ -n "$CORPUS_DIR" ]]; then
  # Copy the read-only share to the guest disk when it fits (corpus size plus 2 GiB free); else read it in place.
  corpus_in_place=1
  corpus_src="/Volumes/My Shared Files/corpus"
  corpus_kb=$(gx "du -sk '$corpus_src' | cut -f1" | tr -d '[:space:]')
  guest_free_kb=$(gx "df -k / | awk 'NR == 2 { print \$4 }'" | tr -d '[:space:]')
  if (( guest_free_kb > corpus_kb + 2 * 1024 * 1024 )); then
    log "Guest: copying the corpus ($(( corpus_kb / 1024 )) MiB) to the guest disk"
    gx "cp -R '$corpus_src' /Users/admin/corpus" && corpus_in_place=0
  fi
  if (( corpus_in_place )); then
    log "Guest: reading the corpus in place from the share"
    corpus_guest="$corpus_src"
  else
    corpus_guest="/Users/admin/corpus"
  fi
  sample_args=""
  [[ -n "$CORPUS_SAMPLE" ]] && sample_args="--sample $CORPUS_SAMPLE --seed 1"
  run_step corpus-run "RUN_ID=$RUN_ID CORPUS_IN_PLACE=$corpus_in_place COMMIT_FILE=$GUEST_RESULTS/commit.txt scripts/run-skin-corpus.sh '$corpus_guest' $GUEST_RESULTS/corpus $sample_args"
  report_sample=1000
  [[ -n "$CORPUS_SAMPLE" ]] && report_sample=$CORPUS_SAMPLE
  run_step corpus-report "BIN=\$(swift build -c release --package-path Packages/SkinKit --show-bin-path)/skintool; \$BIN corpus-report $GUEST_RESULTS/corpus/results.jsonl --markdown $GUEST_RESULTS/corpus/report.md --json $GUEST_RESULTS/corpus/summary.json --env $GUEST_RESULTS/corpus/env.json --crashes $GUEST_RESULTS/corpus/crashes --sample $report_sample --seed 1"
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
grep -hE 'Test run with|smoke: ok|quicklook:|stress:|^corpus:|gate:|main window complete|TEST (SUCCEEDED|FAILED)|BUILD (SUCCEEDED|FAILED)|^(diff|noref) ' "$RESULTS_DIR"/*.log 2>/dev/null | sed 's/^/    /' || true
if (( io_events > 0 )); then
  log "AUDIO  host coreaudiod logged $io_events 'Starting IO' event(s) since $START_STAMP -- something reached a speaker (could be another app)"
  overall=1
else
  log "AUDIO  silent: no host 'Starting IO' events during the run"
fi
log "Logs: $RESULTS_DIR"
exit $overall
