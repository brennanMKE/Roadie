#!/bin/zsh
# make-screenshots.sh — the website's skin screenshots, made in a silent, disposable Tart VM (#0168).
#
# Builds Roadie in a clone of the golden image (never on the host), then for each featured skin launches it with
# the main, equalizer and playlist windows docked, plays a folder of Electronic tracks on This Mac (local files),
# waits ~4 s so the time display, scrolling title and visualizer show activity, and captures the window stack.
# Writes website/assets/screens/<slug>.png (twice the skin's native pixel size, nearest-neighbour), <slug>.webp
# when cwebp is on the host, and manifest.json.
#
# Usage: scripts/make-screenshots.sh [--skins DIR] [--music DIR] [--out DIR]
#   --skins DIR  folder holding the featured .wsz files (default: Skins/ of the main checkout; never committed)
#   --music DIR  folder of audio files to play (default: ~/Library/Caches/co.sstools.roadie-screens/music, fetched
#                once over ssh from $MEDIA_HOST, default "joe"; never committed)
#   --out DIR    output folder (default: website/assets/screens)
#
# Silence and safety:
#   - The guest boots with --no-audio (no path to the host's speakers) and its output muted, as run-tests-vm.sh does.
#   - Music Assistant is NOT configured in the guest: no server, no token, no Sendspin player. Roadie only plays local
#     files on This Mac, so no command can reach a real speaker. (Connecting to Music Assistant was ruled out: on
#     connect Roadie adopts an output that is already playing and can send it transport commands, #0118/#0121.)
#   - One VM at a time through tart-lease; the clone is stopped and deleted on exit.
#   - The host's coreaudiod log is checked afterwards, like run-tests-vm.sh.
#
# Exit codes: 0 ok, 1 a step failed, 2 bad arguments, 3 the guest never came up.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKINS_DIR=""
MUSIC_DIR="$HOME/Library/Caches/co.sstools.roadie-screens/music"
OUT_DIR="$REPO/website/assets/screens"
MEDIA_HOST="${MEDIA_HOST:-joe}"
MEDIA_ROOT="${MEDIA_ROOT:-/Volumes/Media/Media/Music}"

args=("$@")
while (( $#args )); do
  arg=$args[1]; shift args
  case "$arg" in
    --skins) SKINS_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -d "$SKINS_DIR" ]] || { print -r -- "--skins needs a directory" >&2; exit 2 } ;;
    --music) MUSIC_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$MUSIC_DIR" ]] || { print -r -- "--music needs a directory" >&2; exit 2 } ;;
    --out) OUT_DIR=${args[1]:-}; shift args 2>/dev/null; [[ -n "$OUT_DIR" ]] || { print -r -- "--out needs a directory" >&2; exit 2 } ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The featured skins: source file | slug | display name | author (from the readme inside the .wsz; "-" when none).
SKINS=(
  "Deus_AMP.wsz|deus-amp|Deus AMP|Josef \"BladeRay\" Novak"
  "Asian Dragon.wsz|asian-dragon|Asian Dragon|sir-akmal-ez"
  "nightcrawler_by_t_k.wsz|nightcrawler|The NightCrawler|Anuja and Arjuna Navaratna (t-k)"
  "makemesad.wsz|make-me-sad|Make Me Sad|Valerie"
  "Winamp_Classic_CM.wsz|winamp-classic-cm|Winamp Classic CM|-"
)
# Roadie has no built-in skin: with none loaded it shows a "No Skin Loaded" placeholder, so there is nothing to feature.
# Skins drawn for a different stack order (their readme says so): equalizer on top, then main, then playlist.
EQ_FIRST=(deus-amp)

# The Electronic tracks, relative to $MEDIA_ROOT on $MEDIA_HOST; played in this order.
TRACKS=(
  "Daft Punk/Human After All/09 Technologic.m4a"
  "The Chemical Brothers/The Chemical Brothers - Leave Home.mp3"
  "Aphex Twin/Aphex Twin - Windowlicker.mp3"
  "BT/Movement in Still Life/10 Smartbomb.mp3"
  "Digitalism/Idealism/07 Pogo.m4a"
  "Orbital/Orbital - Chime.mp3"
  "Underworld/Underworld - Cow Girl.mp3"
  "The Crystal Method/The Crystal Method - Busy Child.mp3"
)

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CLONE="roadie-screens-$RUN_ID"
EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/roadie-screens-export.XXXXXX")"
GUEST_SRC="/Users/admin/src"
GUEST_OUT="/Users/admin/screens"
GUEST_MUSIC="/Users/admin/Music/Screens"
APP="$GUEST_SRC/build/DerivedData/Build/Products/Debug/Roadie.app"
BOOT_TIMEOUT_SECS=120
LEASE_ID=""
START_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  trap - EXIT
  log "Cleaning up (exit $rc)"
  [[ -n "$LEASE_ID" ]] && { tart-lease release --id "$LEASE_ID" 2>/dev/null || true; }
  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  rm -rf "$EXPORT"
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------

command -v tart >/dev/null || fail "Tart is not installed"
command -v tart-golden >/dev/null || fail "tart-golden not on PATH"
command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"
GOLDEN="$(tart-golden require --xcode 27.0)"

if [[ -z "$SKINS_DIR" ]]; then
  SKINS_DIR="$REPO/Skins"
  # In a worktree the gitignored Skins/ lives only in the main checkout.
  [[ -d "$SKINS_DIR" ]] || SKINS_DIR="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/Skins"
fi
for entry in $SKINS; do
  src=${entry%%|*}
  [[ "$src" == "-" || -f "$SKINS_DIR/$src" ]] || fail "missing skin: $SKINS_DIR/$src"
done

# Music: fetched once into a cache outside the repo, numbered so the folder sorts into play order.
mkdir -p "$MUSIC_DIR"
music_files=()
i=0
for t in $TRACKS; do
  i=$(( i + 1 ))
  dest="$MUSIC_DIR/$(printf %02d $i) ${t:t}"
  music_files+=("$dest")
  [[ -s "$dest" ]] && continue
  log "Fetching track $i from $MEDIA_HOST"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$MEDIA_HOST" "cat ${(q)MEDIA_ROOT}/${(q)t}" >"$dest.part" \
    && mv "$dest.part" "$dest" || { rm -f "$dest.part"; fail "could not fetch track $i from $MEDIA_HOST"; }
done

# --- Export ------------------------------------------------------------------
# The working tree (tracked plus untracked-but-not-ignored), like run-tests-vm.sh; skins and music go into the
# throwaway export only.

mkdir -p "$EXPORT/src" "$EXPORT/skins" "$EXPORT/music"
log "Exporting the working tree"
( cd "$REPO" && git ls-files -z -co --exclude-standard \
    | while IFS= read -r -d '' f; do [[ -e "$f" ]] && print -rN -- "$f"; done ) \
  | rsync -a --from0 --files-from=- "$REPO/" "$EXPORT/src/"
xcodegen generate --quiet --spec "$EXPORT/src/project.yml"
for entry in $SKINS; do
  src=${entry%%|*}
  [[ "$src" == "-" ]] || cp "$SKINS_DIR/$src" "$EXPORT/skins/"
done
cp "${music_files[@]}" "$EXPORT/music/"

# --- Clone and boot ------------------------------------------------------------

if command -v tart-lease >/dev/null; then
  LEASE_ID=$(tart-lease acquire --label roadie-screens --pid $$)
else
  log "WARNING: tart-lease not on PATH -- running without admission control"
fi
log "Cloning $GOLDEN -> $CLONE"
tart clone "$GOLDEN" "$CLONE"
# Tall enough for the docked stack at one pixel per point (the golden's 1024x768 is not), and wide enough that the
# stack sits clear of the 960 pt Library window SwiftUI opens, centred, when the music folder is opened.
tart set "$CLONE" --display 2560x1300px
log "Booting headless, no audio device, export mounted read-only"
tart run "$CLONE" --no-graphics --no-audio --dir=run:"$EXPORT":ro >"$EXPORT/tart-run.log" 2>&1 &
boot_deadline=$(( SECONDS + BOOT_TIMEOUT_SECS ))
until tart exec "$CLONE" true >/dev/null 2>&1; do
  (( SECONDS < boot_deadline )) || { log "INFRA  guest not reachable within ${BOOT_TIMEOUT_SECS}s"; exit 3; }
  sleep 3
done
log "Guest reachable"

gx() { tart exec "$CLONE" /bin/zsh -lc "$1"; }
SHARE="/Volumes/My Shared Files/run"
gx "rm -rf $GUEST_SRC $GUEST_OUT $GUEST_MUSIC && mkdir -p $GUEST_OUT ${GUEST_MUSIC:h} /Users/admin/Skins && cp -R '$SHARE/src' $GUEST_SRC \
  && cp -R '$SHARE/music' $GUEST_MUSIC && cp '$SHARE/skins/'* /Users/admin/Skins/ 2>/dev/null; true" || fail "guest prepare failed"
# --no-audio only cuts the guest's path to the host; mute the guest's own output as well.
gx "osascript -e 'set volume output volume 0' -e 'set volume with output muted' >/dev/null 2>&1 || true"

# --- Build -------------------------------------------------------------------

log "Guest: building Roadie (Debug)"
gx "cd $GUEST_SRC && xcodebuild -quiet -project Roadie.xcodeproj -scheme Roadie -configuration Debug -derivedDataPath build/DerivedData build >/tmp/app-build.log 2>&1 \
  || { grep -E 'error:' /tmp/app-build.log | head -30; tail -20 /tmp/app-build.log; exit 1; }" || fail "app build failed"
gx "swiftc -O -o /Users/admin/capture-roadie-windows $GUEST_SRC/scripts/capture-roadie-windows.swift" || fail "helper build failed"
# A plain dark desktop: it shows through any transparent (region.txt) part of a skin.
gx "/Users/admin/capture-roadie-windows wallpaper 101014" || fail "could not set the desktop picture"

# --- Capture -----------------------------------------------------------------
# Window layout, in desktop points measured down from the top of the primary screen; on the right, clear of the
# desktop widgets (top left) and of notification banners (top right). Roadie draws one skin pixel as two points: main
# and equalizer are 116 skin px (232 pt) tall; the playlist is 116 + 3 * 29 = 203 px (406 pt).

STACK_LEFT=1850
layout_hex() {  # order of kinds, top to bottom
  local top=150 json='{"version":1,"windows":{' sep="" kind
  for kind in "$@"; do
    json+="$sep\"$kind\":{\"left\":$STACK_LEFT,\"top\":$top}"; sep=","
    case $kind in main|equalizer) top=$(( top + 232 )) ;; playlist) top=$(( top + 406 )) ;; esac
  done
  json+='}}'
  print -rn -- "$json" | xxd -p | tr -d '\n'
}

DOM=co.sstools.roadie
captured=()
for entry in $SKINS; do
  IFS='|' read -r src slug name author <<<"$entry"
  if (( ${EQ_FIRST[(Ie)$slug]} )); then hex=$(layout_hex equalizer main playlist); else hex=$(layout_hex main equalizer playlist); fi
  skin_cmd="defaults delete $DOM lastSkinPath >/dev/null 2>&1 || true"
  [[ "$src" == "-" ]] || skin_cmd="defaults write $DOM lastSkinPath ${(qq):-/Users/admin/Skins/$src}"
  log "Guest: capturing $slug"
  gx "pkill -x Roadie; sleep 1; rm -f ~/Library/Application\\ Support/$DOM/queue.json
    $skin_cmd
    defaults write $DOM eqWindowOpen -bool YES
    defaults write $DOM playlistWindowOpen -bool YES
    defaults write $DOM playlistWindowSize -array -integer 0 -integer 3
    defaults write $DOM windowLayout -data $hex
    defaults write $DOM SUEnableAutomaticChecks -bool NO
    open -a $APP && sleep 4 && open -a $APP ${(qq)GUEST_MUSIC} && sleep 4.5 \
      && /Users/admin/capture-roadie-windows capture $GUEST_OUT/$slug.png $STACK_LEFT" || fail "capture failed for $slug"
  captured+=("$entry")
done
gx "pkill -x Roadie; true"

# --- Results back --------------------------------------------------------------

mkdir -p "$OUT_DIR"
# Replace the previous set, so a skin dropped from the list does not linger.
rm -f "$OUT_DIR"/*.png(N) "$OUT_DIR"/*.webp(N) "$OUT_DIR/manifest.json"
gx "tar -C $GUEST_OUT -cf - ." | tar -x -C "$OUT_DIR"

manifest_rows=()
for entry in $captured; do
  IFS='|' read -r src slug name author <<<"$entry"
  png="$OUT_DIR/$slug.png"
  [[ -f "$png" ]] || fail "missing $png"
  w=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ { print $2 }')
  h=$(sips -g pixelHeight "$png" | awk '/pixelHeight/ { print $2 }')
  if command -v cwebp >/dev/null; then cwebp -quiet -lossless -z 9 "$png" -o "$OUT_DIR/$slug.webp"; fi
  manifest_rows+=("$slug"$'\t'"$slug.png"$'\t'"$w"$'\t'"$h"$'\t'"$name"$'\t'"$author"$'\t'"$src")
done
print -rl -- $manifest_rows | python3 -I -c '
import json, sys
rows = []
for line in sys.stdin.read().splitlines():
    slug, file, w, h, name, author, src = line.split("\t")
    rows.append({"slug": slug, "file": file, "width": int(w), "height": int(h), "skin": name,
                 "author": None if author == "-" else author, "source": None if src == "-" else src})
print(json.dumps(rows, indent=2, ensure_ascii=False))
' >"$OUT_DIR/manifest.json"
log "Wrote ${#captured} screenshots and manifest.json to $OUT_DIR"

# --- Host audio check ------------------------------------------------------------

io_events=$(/usr/bin/log show --start "$START_STAMP" \
  --predicate 'process == "coreaudiod" AND eventMessage CONTAINS "Starting IO"' 2>/dev/null \
  | grep -vc '^Timestamp' || true)
if (( io_events > 0 )); then
  log "AUDIO  host coreaudiod logged $io_events 'Starting IO' event(s) since $START_STAMP (could be another app)"
  exit 1
fi
log "AUDIO  silent: no host 'Starting IO' events during the run"
