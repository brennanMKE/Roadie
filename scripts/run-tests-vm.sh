#!/bin/zsh
# run-tests-vm.sh — build and test SkinAmp inside a disposable Tart VM.
#
# Tests and builds never run on the host; see docs/testing-in-vm.md. Each run
# clones the shared golden image (resolved by `tart-golden`, never hardcoded),
# boots it headless with audio cut off from the host (`--no-audio`) and the guest
# output muted, runs the checks, pulls the logs back to build/vm-tests/<run-id>/,
# and deletes the clone.
#
# Usage: scripts/run-tests-vm.sh [--head] [--build-only] [--full] [--launch] [--skins DIR [--references DIR]] [--stress N [--stress-filter F] [--stress-package P] [--load]] [--corpus DIR [--corpus-sample N]] [--spike] [--dmg]
#   --head    test the last commit (git archive HEAD) instead of the working tree
#   --build-only  stop after the build stage (both packages with their tests, the app; with --spike the spike too):
#                 a quick compile check before a full run, never verification
#   --full    also run the slow tier: the 100k SkinLibrary scale tests (SKINAMP_SLOW_TESTS=1) and the
#             real-time AudioCore tests (AUDIOCORE_REALTIME=1); default is the fast tier
#   --launch  also launch the built app in the guest for a few seconds (smoke test)
#   --skins DIR  copy DIR/*.wsz into the guest's Skins/; adds steps skintool and skintool-png, runs sampleSkinsAreOk
#   --references DIR  with --skins: copy DIR/*.png (scripts/fetch-webamp-references.sh output) into Skins/reference/
#                     and diff each render against them in skintool-png (numbers only, never gated)
#   --stress N  also repeat the real-time gapless test N times in the guest (step playerkit-stress)
#   --stress-filter F  with --stress: loop the `swift test --filter` F instead (default: the gapless test)
#   --stress-package P  with --stress: SkinKit or PlayerKit (default PlayerKit); the step is <p>-stress (#0094)
#   --load      with --stress: run four CPU hogs in the guest during the loop
#   --corpus DIR  run every .wsz/.zip under DIR (any layout) through `skintool corpus` in the guest (#0038): shared read-only
#                 as a second virtio-fs share, copied to the guest disk, then steps corpus-run and corpus-report; the
#                 corpus never enters git or the export. Results in build/vm-tests/<run-id>/corpus/
#   --corpus-sample N  with --corpus: only a seeded sample of N unique skins (the fast loop; 1000 is the acceptance sample)
#   --spike  also build, test and smoke-launch the AirPlay routing spike harness (#0050): steps spike-pkg-build, spike-build, spike-tests, spike-smoke;
#            the smoke launch constructs every engine and never plays
#   --dmg    also build the app in the Release configuration (step app-release) and bring it back, zipped, as
#            build/vm-tests/<run-id>/release/SkinAmp.app.zip; scripts/make-dmg.sh signs it on the host and makes the DMG
#
# In the guest, in order:
#   Build stage (a failure here skips everything below and prints the compiler errors):
#   1. swift build --build-tests --package-path Packages/SkinKit, then Packages/PlayerKit
#   2. xcodebuild ... build                             (project generated on the host; only if both packages built)
#   Tests and checks, reusing those builds:
#   3. swift test --skip-build --package-path Packages/SkinKit  (SKIN_SAMPLES_DIR=Skins with --skins; SKINAMP_SLOW_TESTS=1 with --full)
#      skintool Skins/ (only with --skins; fails unless every skin is ok), then skintool --png into results/png/
#   4. swift test --skip-build --package-path Packages/PlayerKit  (with --full: AUDIOCORE_REALTIME=1, muted)
#   5. scripts/check-info-plist.sh on the built app's Info.plist (networking keys, .wsz type)
#      scripts/check-entitlements.sh on the built app (Location entitlement, #0075)
#   6. scripts/check-quicklook.sh: register the Quick Look extensions, qlmanage -t / -p a generated skin (#0043)
#   7. optional: launch SkinAmp.app, check it stays up, quit it
# Exit codes:
#   0  everything passed and the host stayed silent
#   1  a build/test/check step failed, the host's coreaudiod logged "Starting IO" during
#      the run (anything reached a speaker), or a preflight check failed
#   2  bad arguments
#   3  infrastructure: the guest didn't boot or was lost mid-run (summary line INFRA);
#      not a code problem, rerun
# The summary (from the first PASS/FAIL/SKIP line, or the INFRA line if the guest never came up, to the
# final "Cleaning up (exit N)") is also written to build/vm-tests/<run-id>/summary.txt; the last line printed names it.
# Usage errors (exit 2) and preflight failures (exit 1, "!!" on stderr) print no summary and write no file.

set -euo pipefail

USE_HEAD=0
BUILD_ONLY=0
FULL=0
LAUNCH=0
STRESS=0
STRESS_FILTER=""
STRESS_PACKAGE=""
LOAD=0
SPIKE=0
DMG=0
SKINS_DIR=""
REFS_DIR=""
CORPUS_DIR=""
CORPUS_SAMPLE=""
args=("$@")
while (( $#args )); do
  arg=$args[1]; shift args
  case "$arg" in
    --head) USE_HEAD=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    --full) FULL=1 ;;
    --launch) LAUNCH=1 ;;
    --stress) STRESS=${args[1]:-}; shift args 2>/dev/null; [[ "$STRESS" == <1-> ]] || { print -r -- "--stress needs a positive count" >&2; exit 2 } ;;
    --stress-filter) STRESS_FILTER=${args[1]:-}; shift args 2>/dev/null; [[ -n "$STRESS_FILTER" ]] || { print -r -- "--stress-filter needs a test filter" >&2; exit 2 } ;;
    --stress-package) STRESS_PACKAGE=${args[1]:-}; shift args 2>/dev/null; [[ "$STRESS_PACKAGE" == (SkinKit|PlayerKit) ]] || { print -r -- "--stress-package needs SkinKit or PlayerKit" >&2; exit 2 } ;;
    --load) LOAD=1 ;;
    --spike) SPIKE=1 ;;
    --dmg) DMG=1 ;;
    --skins) SKINS_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$SKINS_DIR" && -d "$SKINS_DIR" ]] || { print -r -- "--skins needs a directory of .wsz files" >&2; exit 2 } ;;
    --references) REFS_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$REFS_DIR" && -d "$REFS_DIR" ]] || { print -r -- "--references needs a directory of reference PNGs" >&2; exit 2 } ;;
    --corpus) CORPUS_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$CORPUS_DIR" && -d "$CORPUS_DIR" ]] || { print -r -- "--corpus needs a directory of .wsz/.zip files" >&2; exit 2 } ;;
    --corpus-sample) CORPUS_SAMPLE=${args[1]:-}; shift args 2>/dev/null; [[ "$CORPUS_SAMPLE" == <1-> ]] || { print -r -- "--corpus-sample needs a positive count" >&2; exit 2 } ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $arg" >&2; exit 2 ;;
  esac
done

(( LOAD && ! STRESS )) && { print -r -- "--load needs --stress N" >&2; exit 2 }
[[ -n "$STRESS_FILTER" ]] && (( ! STRESS )) && { print -r -- "--stress-filter needs --stress N" >&2; exit 2 }
[[ -n "$STRESS_PACKAGE" ]] && (( ! STRESS )) && { print -r -- "--stress-package needs --stress N" >&2; exit 2 }
if (( BUILD_ONLY )); then
  for f v in --stress "$STRESS" --stress-package "$STRESS_PACKAGE" --load "$LOAD" --launch "$LAUNCH" --corpus "$CORPUS_DIR" --corpus-sample "$CORPUS_SAMPLE" \
             --skins "$SKINS_DIR" --references "$REFS_DIR" --full "$FULL"; do
    [[ -n "$v" && "$v" != 0 ]] && { print -r -- "--build-only runs no tests; drop $f" >&2; exit 2 }
  done
fi
TIER=fast; slow_env=""; rt_env=""
(( FULL )) && { TIER=full; slow_env="SKINAMP_SLOW_TESTS=1 "; rt_env="AUDIOCORE_REALTIME=1 " }
(( BUILD_ONLY )) && TIER=build-only
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
SUMMARY_FILE=""

log()  { print -r -- "==> $*"; if [[ -n "$SUMMARY_FILE" ]]; then print -r -- "==> $*" >>"$SUMMARY_FILE"; fi; }
fail() { print -r -- "!! $*" >&2; exit 1; }
# Start teeing every log line (and the indented summary blocks) into summary.txt.
summary_start() { mkdir -p "$RESULTS_DIR"; SUMMARY_FILE="$RESULTS_DIR/summary.txt"; : >"$SUMMARY_FILE"; }
infra_fail() {
  summary_start
  cp "$EXPORT/tart-run.log" "$RESULTS_DIR/" 2>/dev/null || true
  log "INFRA  $*"
  log "Logs: $RESULTS_DIR"
  exit 3
}

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
  if [[ -n "$SUMMARY_FILE" ]]; then log "Summary: $SUMMARY_FILE"; fi
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

# A SIGKILL or OOM kill skips the trap, so sweep clones whose run is gone. Two
# concurrent runs are expected (tart-lease allows two), so a clone whose <pid> is
# still a live run-tests-vm.sh is left alone, unless its run id is older than
# MAX_RUN_HOURS (pid reuse backstop). Only names shaped exactly like this script's
# run IDs are touched; the golden can't match.
# Max plausible run: a full --corpus run plus --stress 200 is well under this.
MAX_RUN_HOURS=8
run_is_live() {   # true if <pid> is a live run-tests-vm.sh process
  local cmd
  cmd=$(ps -p "$1" -o command= 2>/dev/null) || return 1
  [[ "$cmd" == *run-tests-vm.sh* ]]
}
for old in $(tart list --quiet); do
  [[ "$old" =~ '^skinamp-test-([0-9]{8})-([0-9]{6})-([0-9]+)$' ]] || continue
  [[ "$old" == "$CLONE" || "$old" == "$GOLDEN" ]] && continue
  pid=$match[3]
  started=$(date -j -f '%Y%m%d%H%M%S' "$match[1]$match[2]" +%s 2>/dev/null) || started=0
  age_h=$(( ($(date +%s) - started) / 3600 ))
  if run_is_live "$pid" && (( age_h < MAX_RUN_HOURS )); then
    log "Leaving clone of a live run: $old (pid $pid)"; continue
  fi
  log "Sweeping stale clone: $old (pid $pid not a live run$( (( age_h >= MAX_RUN_HOURS )) && print -n ", ${age_h}h old"))"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done

# --- Export a snapshot -----------------------------------------------------
# Working tree by default (tracked plus untracked-but-not-ignored files), so a
# change can be verified before it is committed. Never shared read-write.

mkdir -p "$EXPORT/src"
log "Tier: $TIER"
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
  (( SECONDS < boot_deadline )) || infra_fail "guest not reachable within ${BOOT_TIMEOUT_SECS}s (see $RESULTS_DIR/tart-run.log)"
  sleep 3
done
log "Guest reachable"

gx() { tart exec "$CLONE" /bin/zsh -lc "$1"; }
# Probe twice so one transport hiccup doesn't count; a stopped VM fails tart exec at once.
guest_alive() { tart exec "$CLONE" true >/dev/null 2>&1 && return 0; sleep 2; tart exec "$CLONE" true >/dev/null 2>&1; }
# gx_prep cmd: a prep command whose failure is fatal; a dead guest is reported as INFRA.
gx_prep() { gx "$1" && return 0; guest_alive && fail "Guest prepare step failed: $1"; infra_fail "guest lost during prepare"; }

gx_prep "rm -rf $GUEST_SRC $GUEST_RESULTS && mkdir -p $GUEST_RESULTS && cp -R '/Volumes/My Shared Files/run/src' $GUEST_SRC"
# The guest still has a virtual sound device; --no-audio only cuts its path to the
# host. Mute it as well, and record the device list and mute state as evidence.
gx_prep "osascript -e 'set volume output volume 0' -e 'set volume with output muted' >/dev/null 2>&1 || true"
gx_prep "{ system_profiler SPAudioDataType; print -- '--- output volume settings:'; osascript -e 'get volume settings'; } > $GUEST_RESULTS/audio-devices.txt 2>&1 || true"

# The export has no .git; the corpus report wants the commit.
commit_text="$(git -C "$REPO" rev-parse --short HEAD)"
(( USE_HEAD )) || git -C "$REPO" diff --quiet HEAD -- 2>/dev/null || commit_text="$commit_text-dirty"
gx_prep "print -r -- '$commit_text' > $GUEST_RESULTS/commit.txt"
gx_prep "print -r -- '$TIER' > $GUEST_RESULTS/tier.txt"

# --- Steps -----------------------------------------------------------------
# `set -o pipefail` inside the guest shell: without it the status is tee's.

typeset -A step_rc; typeset -a step_order; build_failed=0; guest_lost=0; lost_step=""
# run_step name cmd [stage]: stage "build" marks the run failed on error; "test" steps are skipped once it is.
# A non-zero step whose guest no longer answers is "lost" (infrastructure), never a build failure.
run_step() {
  local name=$1 cmd=$2 stage=${3:-test}
  if (( guest_lost )); then skip_step $name; return 0; fi
  step_order+=($name)
  if (( build_failed )) && [[ $stage == test ]]; then step_rc[$name]=skip; log "Skip: $name (build failed)"; return; fi
  log "Guest: $name"
  set +e
  gx "set -o pipefail; cd $GUEST_SRC && { $cmd; } 2>&1 | tee $GUEST_RESULTS/$name.log"
  step_rc[$name]=$?
  set -e
  if (( step_rc[$name] != 0 )) && ! guest_alive; then
    step_rc[$name]=lost; guest_lost=1; lost_step=$name
    log "Guest lost during $name"
    return 0
  fi
  [[ $stage == build ]] && (( step_rc[$name] != 0 )) && build_failed=1
  return 0
}
skip_step() {
  step_order+=($1)
  if (( guest_lost )); then step_rc[$1]=lost-skip; log "Skip: $1 (guest lost)"
  else step_rc[$1]=skip; log "Skip: $1 (build failed)"; fi
}

# --- Build stage -------------------------------------------------------------
# Build everything once; the tests below reuse it. Both packages always build so one run reports both.
run_step skinkit-build   "swift build --build-tests --package-path Packages/SkinKit" build
run_step playerkit-build "swift build --build-tests --package-path Packages/PlayerKit" build
APP_BUILD="xcodebuild -project SkinAmp.xcodeproj -scheme SkinAmp -configuration Debug -derivedDataPath build/DerivedData build"
if (( build_failed )); then skip_step app-build; else run_step app-build "$APP_BUILD" build; fi
if (( SPIKE )); then
  if (( build_failed )); then
    skip_step spike-pkg-build; skip_step spike-build
  else
    run_step spike-pkg-build "swift build --build-tests --package-path Spikes/AirPlaySpike/SpikeKit" build
    if (( build_failed )); then skip_step spike-build; else
      run_step spike-build "xcodebuild -project Spikes/AirPlaySpike/AirPlaySpike.xcodeproj -scheme AirPlaySpike -configuration Debug -derivedDataPath build/DerivedData-spike build" build
    fi
  fi
fi

# --- Tests and checks --------------------------------------------------------

if (( ! BUILD_ONLY )); then
if [[ -n "$SKINS_DIR" ]]; then
  run_step skinkit-tests "${slow_env}SKIN_SAMPLES_DIR=$GUEST_SRC/Skins swift test --skip-build --package-path Packages/SkinKit"
  run_step skintool      "swift run --skip-build --package-path Packages/SkinKit skintool -v Skins/"
  # Headless render of every skin to PNG (and, with --references, a diff against the Webamp screenshots).
  compare=""
  [[ -n "$REFS_DIR" ]] && compare="--compare $GUEST_SRC/Skins/reference"
  run_step skintool-png  "swift run --skip-build --package-path Packages/SkinKit skintool --png $GUEST_RESULTS/png $compare Skins/"
else
  run_step skinkit-tests "${slow_env}swift test --skip-build --package-path Packages/SkinKit"
fi
# With --full the real-time tests run here too: the guest's virtual output device has no path to
# the host (--no-audio), the guest is muted, and the tests mute their own mixer.
run_step playerkit-tests "${rt_env}swift test --skip-build --package-path Packages/PlayerKit"
if (( STRESS )); then
  STRESS_PACKAGE=${STRESS_PACKAGE:-PlayerKit}
  stress_filter_arg="''"; [[ -n "$STRESS_FILTER" ]] && stress_filter_arg=${(q)STRESS_FILTER}
  run_step ${STRESS_PACKAGE:l}-stress "scripts/stress-realtime-gapless.sh $STRESS $LOAD $stress_filter_arg $STRESS_PACKAGE"
fi
run_step app-plist       "scripts/check-info-plist.sh build/DerivedData/Build/Products/Debug/SkinAmp.app/Contents/Info.plist"
run_step app-entitlements "scripts/check-entitlements.sh build/DerivedData/Build/Products/Debug/SkinAmp.app"
run_step app-quicklook   "scripts/check-quicklook.sh build/DerivedData/Build/Products/Debug/SkinAmp.app $GUEST_RESULTS/ql"
if (( LAUNCH )); then
  run_step app-launch "open build/DerivedData/Build/Products/Debug/SkinAmp.app && sleep 5 && pgrep -x SkinAmp && osascript -e 'quit app \"SkinAmp\"' && sleep 1 && ! pgrep -x SkinAmp"
fi

if (( SPIKE )); then
  # check-sdk.sh prints the long-form SDK findings into spike-tests.log first. The smoke launch must never play audio:
  # it constructs every engine and exits; open -W returns when the app quits, the grep is the real pass condition.
  run_step spike-tests "Spikes/AirPlaySpike/check-sdk.sh && swift test --skip-build --package-path Spikes/AirPlaySpike/SpikeKit"
  run_step spike-smoke "mkdir -p $GUEST_RESULTS/spike && open -W -n build/DerivedData-spike/Build/Products/Debug/AirPlaySpike.app --args --smoke --log-dir $GUEST_RESULTS/spike && grep -q 'smoke: ok' $GUEST_RESULTS/spike/smoke.log && cat $GUEST_RESULTS/spike/smoke.log && ! pgrep -x AirPlaySpike"
fi

if [[ -n "$CORPUS_DIR" ]] && (( build_failed || guest_lost )); then
  skip_step corpus-run; skip_step corpus-report
elif [[ -n "$CORPUS_DIR" ]]; then
  # Copy the read-only share to the guest disk when it fits (corpus size plus 2 GiB free); else read it in place.
  corpus_in_place=1
  corpus_src="/Volumes/My Shared Files/corpus"
  corpus_kb=$(gx "du -sk '$corpus_src' | cut -f1" | tr -d '[:space:]') || true
  guest_free_kb=$(gx "df -k / | awk 'NR == 2 { print \$4 }'" | tr -d '[:space:]') || true
  if (( ${guest_free_kb:-0} > ${corpus_kb:-0} + 2 * 1024 * 1024 )); then
    log "Guest: copying the corpus ($(( corpus_kb / 1024 )) MiB) to the guest disk"
    gx "cp -R '$corpus_src' /Users/admin/corpus" && corpus_in_place=0
  fi
  guest_alive || { guest_lost=1; lost_step=corpus-prepare; log "Guest lost during corpus-prepare"; }
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
fi  # ! BUILD_ONLY

if (( DMG )); then
  # Release build for scripts/make-dmg.sh. Zipped with ditto so the bundle's symlinks and signature survive the tar back.
  # The build number (CFBundleVersion) is a UTC date and time, computed once on the host (#0127); the command-line
  # override reaches every target, so the app and its Quick Look extensions share it. Debug builds keep project.yml's 1.
  BUILD_NUMBER=$(date -u +%Y%m%d.%H%M)
  run_step app-release "xcodebuild -project SkinAmp.xcodeproj -scheme SkinAmp -configuration Release -derivedDataPath build/DerivedData-release CURRENT_PROJECT_VERSION=$BUILD_NUMBER build && mkdir -p $GUEST_RESULTS/release && print -r -- $BUILD_NUMBER > $GUEST_RESULTS/release/build.txt && ditto -c -k --keepParent build/DerivedData-release/Build/Products/Release/SkinAmp.app $GUEST_RESULTS/release/SkinAmp.app.zip"
fi

# --- Results back ----------------------------------------------------------

mkdir -p "$RESULTS_DIR"
if (( ! guest_lost )); then
  gx "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$RESULTS_DIR" \
    || { guest_alive || { guest_lost=1; lost_step=${lost_step:-results}; log "Guest lost during results"; }; }
fi

# --- Host audio check ------------------------------------------------------
# With --no-audio the guest has no path to the host's speakers; prove it.

io_events=$(/usr/bin/log show --start "$START_STAMP" \
  --predicate 'process == "coreaudiod" AND eventMessage CONTAINS "Starting IO"' 2>/dev/null \
  | grep -vc '^Timestamp' || true)

print ""
summary_start
overall=0
for name in $step_order; do
  case ${step_rc[$name]} in
    0) log "PASS  $name" ;;
    skip) log "SKIP  $name (build failed)" ;;
    lost) log "FAIL  $name (guest lost)" ;;
    lost-skip) log "SKIP  $name (guest lost)" ;;
    *) log "FAIL  $name (exit ${step_rc[$name]})"; overall=1 ;;
  esac
done
if (( build_failed )); then
  nskip=${#${(M)${(v)step_rc}:#skip}}
  if (( nskip )); then log "BUILD  failed: $nskip step(s) skipped; fix the errors below and rerun"
  else log "BUILD  failed: fix the errors below and rerun"; fi
  failed_logs=()
  for name in skinkit-build playerkit-build app-build spike-pkg-build spike-build; do
    [[ -n "${step_rc[$name]:-}" && "${step_rc[$name]}" != 0 && "${step_rc[$name]}" != skip && -f "$RESULTS_DIR/$name.log" ]] && failed_logs+=("$RESULTS_DIR/$name.log")
  done
  errs=$(cat "${failed_logs[@]}" 2>/dev/null | perl -pe 's/\e\]8;;.*?\e\\//g; s/\e\[[0-9;]*m//g' \
    | grep -E '^/.*:[0-9]+:[0-9]+: error: ' | sed "s|^$GUEST_SRC/||" | awk '!seen[$0]++' || true)
  if [[ -n "$errs" ]]; then
    log "ERRORS  $(print -r -- "$errs" | wc -l | tr -d ' ') compiler error(s) (first 30; full logs: ${(j:, :)${failed_logs:t}})"
    print -r -- "$errs" | head -30 | sed 's/^/    /' | tee -a "$SUMMARY_FILE"
  else
    for f in $failed_logs; do
      log "ERRORS  no file:line:col errors; tail of ${f:t}"
      sed $'s/\e\\[[0-9;]*m//g' "$f" | grep -v '^[[:space:]]*$' | tail -15 | sed 's/^/    /' | tee -a "$SUMMARY_FILE"
    done
  fi
fi
if (( guest_lost )); then
  log "INFRA  guest lost during $lost_step: the VM stopped or tart exec lost its transport; not a build or test failure -- rerun"
  overall=3
fi
if (( BUILD_ONLY )); then
  (( build_failed || guest_lost )) || log "BUILD-ONLY  everything compiles; no tests ran. This is not verification: run scripts/run-tests-vm.sh for that."
elif (( FULL )); then
  log "TIER  full: includes the 100k scale and real-time audio tests"
else
  log "TIER  fast: 100k scale and real-time audio tests skipped (scripts/run-tests-vm.sh --full runs them)"
fi
step_logs=("$RESULTS_DIR"/*.log(N))  # none when the guest was lost before the results pull
if (( ${#step_logs} )); then
  grep -hE 'Build complete!|Test run with|smoke: ok|quicklook:|stress:|^corpus:|gate:|main window complete|TEST (SUCCEEDED|FAILED)|BUILD (SUCCEEDED|FAILED)|^(diff|noref) ' "${step_logs[@]}" 2>/dev/null | sed 's/^/    /' | tee -a "$SUMMARY_FILE" || true
fi
if (( io_events > 0 )); then
  log "AUDIO  host coreaudiod logged $io_events 'Starting IO' event(s) since $START_STAMP -- something reached a speaker (could be another app)"
  (( overall == 3 )) || overall=1
else
  log "AUDIO  silent: no host 'Starting IO' events during the run"
fi
log "Logs: $RESULTS_DIR"
exit $overall
