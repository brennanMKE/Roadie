#!/bin/zsh
# verify-dmg.sh — check a finished Roadie DMG the way a recipient's Mac will see it. Host only; never launches the app.
#
# Usage: scripts/verify-dmg.sh Roadie-X.Y.Z.dmg [--expect-team ID] [--allow-unnotarized]
#   --expect-team ID     the TeamIdentifier every signature must carry (default: the DMG's own)
#   --allow-unnotarized  the notarization-dependent checks (stapler, spctl on the DMG and the app, quarantine
#                        simulation) are reported as EXPECTED-FAIL and don't fail the exit code
# Prints one PASS/FAIL line per check; exits 1 if any non-allowed check fails.

set -euo pipefail
if [[ -o xtrace ]]; then print -u2 "verify-dmg.sh: refusing to run with xtrace on"; exit 2; fi

DMG=""
TEAM=""
ALLOW_UNNOTARIZED=0
while (( $# )); do
  case $1 in
    --expect-team) TEAM=$2; shift 2 ;;
    --allow-unnotarized) ALLOW_UNNOTARIZED=1; shift ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) [[ -z "$DMG" ]] || { print -u2 "verify-dmg.sh: one DMG only"; exit 2 }; DMG=${1:A}; shift ;;
  esac
done
[[ -f "$DMG" ]] || { print -u2 "verify-dmg.sh: give a .dmg"; exit 2 }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/roadie-verify.XXXXXX")
MNT="$WORK/mnt"
cleanup() {
  [[ -d "$MNT/Roadie.app" ]] && hdiutil detach -quiet "$MNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

failures=0 expected=0
# check NAME NOTARY(0|1) CMD... — runs CMD quietly and prints one line.
check() {
  local name=$1 notary=$2; shift 2
  if "$@" >"$WORK/out" 2>&1; then
    print "PASS  $name"
  elif (( notary && ALLOW_UNNOTARIZED )); then
    print "FAIL  $name (expected: not notarized)"; (( ++expected ))
  else
    print "FAIL  $name"; sed 's/^/        /' "$WORK/out" | head -5; (( ++failures ))
  fi
}

if [[ -z "$TEAM" ]]; then
  TEAM=$(codesign -dv "$DMG" 2>&1 | sed -n 's/^TeamIdentifier=//p')
fi

check "DMG signature valid" 0 codesign --verify --strict "$DMG"
check "DMG team is ${TEAM:-?}" 0 zsh -c '[[ -n "$2" ]] && codesign -dv "$1" 2>&1 | grep -qx "TeamIdentifier=$2"' _ "$DMG" "$TEAM"
check "stapler validate (notarization ticket)" 1 xcrun stapler validate "$DMG"
check "spctl open, primary signature" 1 spctl -a -t open --context context:primary-signature "$DMG"

mkdir "$MNT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG"
APP="$MNT/Roadie.app"
check "Roadie.app and Applications link on the volume" 0 test -d "$APP" -a -L "$MNT/Applications"
check "codesign --verify --deep --strict Roadie.app" 0 codesign --verify --deep --strict "$APP"
check "spctl exec Roadie.app" 1 spctl -a -t exec "$APP"

machos=0 bad=()
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  (( ++machos ))
  info=$(codesign -dvvv "$f" 2>&1 || true)
  grep -q '^Signature=adhoc' <<<"$info" && { bad+=("${f#$MNT/}: ad-hoc"); continue }
  grep -qx "TeamIdentifier=$TEAM" <<<"$info" || bad+=("${f#$MNT/}: team")
  grep -q '^Authority=Developer ID Application:' <<<"$info" || bad+=("${f#$MNT/}: authority")
  grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$info" || bad+=("${f#$MNT/}: runtime")
  grep -q '^Timestamp=' <<<"$info" || bad+=("${f#$MNT/}: timestamp")
done < <(find "$APP" -type f -print0)
check "$machos Mach-O files: Developer ID, team, runtime, timestamp" 0 zsh -c '(( $# == 0 )) || { print -l -- "$@"; exit 1 }' _ "${bad[@]}"
hdiutil detach -quiet "$MNT"

# Quarantine simulation: a copy carrying Safari's quarantine flag, assessed like a download.
cp "$DMG" "$WORK/download.dmg"
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;$(uuidgen)" "$WORK/download.dmg"
check "quarantined copy passes spctl" 1 spctl -a -t open --context context:primary-signature "$WORK/download.dmg"

if (( failures )); then
  print "verify-dmg.sh: $failures check(s) failed$( (( expected )) && print ", $expected expected (not notarized)")"; exit 1
fi
print "verify-dmg.sh: all checks passed$( (( expected )) && print ", except $expected notarization check(s), expected")"
