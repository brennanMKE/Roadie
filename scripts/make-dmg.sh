#!/bin/zsh
# make-dmg.sh — sign a Release Roadie.app with Developer ID and package it as a DMG, on the host.
#
# The app is never built here: scripts/verify.sh --head --dmg builds it in the VM and brings it back as
# build/vm-tests/<run-id>/release/Roadie.app.zip. This script only re-signs and packages; it never launches the app.
#
# Usage: scripts/make-dmg.sh Roadie.app.zip [--identity NAME] [--notary-profile PROFILE]
#        scripts/make-dmg.sh Roadie.app.zip --release X.Y.Z [--identity NAME] [--notary-profile PROFILE] [--out DIR]
#   --identity NAME          codesign identity (default: the first "Developer ID Application" in the keychain)
#   --notary-profile PROFILE notarize and staple with this `xcrun notarytool store-credentials` profile;
#                            without it the DMG is signed but not notarized, and Gatekeeper asks once on first open
#   --release X.Y.Z          release mode (docs/design/release.md §2.5 steps 2-8): version gate, Sparkle signing order,
#                            per-Mach-O checks, Roadie.dmg renamed to Roadie-X.Y.Z.dmg after stapling, .sha256,
#                            dSYM zip and dsym-uuids.txt copied from the VM's release folder
#   --out DIR                release output folder (default build/release/X.Y.Z)
#   --allow-version-mismatch testing only: report a version gate failure instead of stopping
# Output (dev mode): build/dist/Roadie-<version>-<build>-<commit>.dmg (commit from the run's commit.txt when present)
# Output (release):  <out>/Roadie-X.Y.Z.dmg and Roadie-X.Y.Z.dmg.sha256 [+ notary-log.json on Invalid]
#
# No secret is ever passed on a command line: the notary credentials live in the keychain profile.

set -euo pipefail
if [[ -o xtrace ]]; then print -u2 "make-dmg.sh: refusing to run with xtrace on"; exit 2; fi
unsetopt xtrace

REPO=${0:A:h:h}
ZIP=""
IDENTITY=""
NOTARY_PROFILE=""
RELEASE=""
OUT=""
COMMIT=""
ALLOW_MISMATCH=0
while (( $# )); do
  case $1 in
    --identity) IDENTITY=$2; shift 2 ;;
    --notary-profile) NOTARY_PROFILE=$2; shift 2 ;;
    --release) RELEASE=$2; shift 2 ;;
    --out) OUT=${2:A}; shift 2 ;;
    --allow-version-mismatch) ALLOW_MISMATCH=1; shift ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) [[ -z "$ZIP" ]] || { print -u2 "make-dmg.sh: one zip only"; exit 2 }; ZIP=${1:A}; shift ;;
  esac
done
[[ -f "$ZIP" ]] || { print -u2 "make-dmg.sh: give the Roadie.app.zip from scripts/verify.sh --head --dmg"; exit 2 }
if [[ -n "$RELEASE" && ! "$RELEASE" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "make-dmg.sh: --release needs X.Y.Z"; exit 2
fi
[[ -z "$OUT" || -n "$RELEASE" ]] || { print -u2 "make-dmg.sh: --out needs --release"; exit 2 }
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  [[ -n "$IDENTITY" ]] || { print -u2 "make-dmg.sh: no Developer ID Application identity; pass --identity"; exit 1 }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/roadie-dmg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/stage"
ditto -x -k "$ZIP" "$WORK/stage"
APP="$WORK/stage/Roadie.app"
[[ -d "$APP" ]] || { print -u2 "make-dmg.sh: no Roadie.app in $ZIP"; exit 1 }

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" }
VERSION=$(plist "$APP" CFBundleShortVersionString)
BUILD=$(plist "$APP" CFBundleVersion)

# Step 2: version gate. The app and every appex must report X.Y.Z (<build>), with one build number throughout.
if [[ -n "$RELEASE" ]]; then
  gate_ok=1
  for b in "$APP" "$APP"/Contents/PlugIns/*.appex(N); do
    v="$(plist "$b" CFBundleShortVersionString) ($(plist "$b" CFBundleVersion))"
    if [[ "$v" != "$RELEASE ($BUILD)" ]]; then
      print -u2 "make-dmg.sh: ${b:t} reports $v, expected $RELEASE ($BUILD)"; gate_ok=0
    fi
  done
  if (( ! gate_ok )); then
    (( ALLOW_MISMATCH )) || exit 1
    print -u2 "make-dmg.sh: --allow-version-mismatch: continuing (testing only, never for a real release)"
  fi
fi

# Step 3: re-sign inside out with the hardened runtime and a timestamp, keeping each bundle's own entitlements minus
# get-task-allow (which notarization rejects). --deep signing is never used.
sign() {
  local target=$1 ents="$WORK/ents-${RANDOM}${RANDOM}.plist"
  codesign -d --entitlements - --xml "$target" >"$ents" 2>/dev/null || true
  if [[ -s "$ents" ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ents" >/dev/null 2>&1 || true
    codesign --force --timestamp --options runtime --entitlements "$ents" --sign "$IDENTITY" "$target"
  else
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$target"
  fi
}

# Sparkle's nested code first (Installer.xpc, Downloader.xpc, Autoupdate, Updater.app), then the framework.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  CUR=$(readlink "$SPARKLE/Versions/Current" 2>/dev/null || print B)
  SV="$SPARKLE/Versions/$CUR"
  for f in "$SV/XPCServices/Installer.xpc" "$SV/XPCServices/Downloader.xpc" "$SV/Autoupdate" "$SV/Updater.app"; do
    if [[ -e "$f" ]]; then sign "$f"; else print "==> note: ${f#$APP/} not present, skipped"; fi
  done
  sign "$SPARKLE"
else
  print "==> note: no Sparkle.framework in the app; skipping the Sparkle helpers"
fi
for f in "$APP"/Contents/Frameworks/*.(framework|dylib)(N); do
  [[ "$f" == "$SPARKLE" ]] || sign "$f"
done
for f in "$APP"/Contents/PlugIns/*.appex(N) "$APP"/Contents/Extensions/*.appex(N); do
  sign "$f"
done
sign "$APP"
codesign --verify --deep --strict "$APP"

# Every Mach-O: not ad-hoc, the app's team, a Developer ID authority, the runtime flag and a secure timestamp.
if [[ -n "$RELEASE" ]]; then
  TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ -n "$TEAM" && "$TEAM" != "not set" ]] || { print -u2 "make-dmg.sh: the app has no TeamIdentifier"; exit 1 }
  bad=0 count=0
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    (( ++count ))
    info=$(codesign -dvvv "$f" 2>&1 || true)
    problems=()
    grep -q '^Signature=adhoc' <<<"$info" && problems+=(ad-hoc)
    grep -qx "TeamIdentifier=$TEAM" <<<"$info" || problems+=(team)
    grep -q '^Authority=Developer ID Application:' <<<"$info" || problems+=(authority)
    grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$info" || problems+=(runtime)
    grep -q '^Timestamp=' <<<"$info" || problems+=(timestamp)
    if (( ${#problems} )); then print -u2 "make-dmg.sh: ${f#$WORK/stage/}: ${problems[*]}"; bad=1; fi
  done < <(find "$APP" -type f -print0)
  (( ! bad )) || exit 1
  print "==> $count Mach-O files: Developer ID, team $TEAM, runtime, timestamp"
fi

# Step 4: DMG.
ln -s /Applications "$WORK/stage/Applications"
if [[ -n "$RELEASE" ]]; then
  OUT=${OUT:-$REPO/build/release/$RELEASE}
  mkdir -p "$OUT"
  DMG="$OUT/Roadie.dmg"   # the working name equals the volume name, so notarization can't rename it
  rm -f "$DMG" "$OUT/Roadie-$RELEASE.dmg" "$OUT/Roadie-$RELEASE.dmg.sha256"
else
  COMMIT=$(cat "${ZIP:h:h}/commit.txt" 2>/dev/null || true)
  mkdir -p "$REPO/build/dist"
  DMG="$REPO/build/dist/Roadie-$VERSION-$BUILD${COMMIT:+-$COMMIT}.dmg"
fi
hdiutil create -quiet -volname Roadie -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# Steps 5-6: notarize and staple. Only the submission id and status are printed.
if [[ -n "$NOTARY_PROFILE" ]]; then
  result=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)
  sub_id=$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$result" 2>/dev/null || true)
  nstatus=$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$result" 2>/dev/null || true)
  print "==> Notarization $sub_id: $nstatus"
  if [[ "$nstatus" != "Accepted" ]]; then
    if [[ -n "$sub_id" ]]; then
      LOGDIR=${OUT:-${DMG:h}}
      xcrun notarytool log "$sub_id" --keychain-profile "$NOTARY_PROFILE" "$LOGDIR/notary-log.json" >/dev/null
      print -u2 "make-dmg.sh: notarization $nstatus; log in $LOGDIR/notary-log.json"
    fi
    exit 1
  fi
  xcrun stapler staple -q "$DMG"
  xcrun stapler validate -q "$DMG"
fi

# Steps 7-8: final name (the bytes are frozen from here) and sha256, then the symbolication files.
if [[ -n "$RELEASE" ]]; then
  FINAL="Roadie-$RELEASE.dmg"
  mv "$DMG" "$OUT/$FINAL"
  DMG="$OUT/$FINAL"
  (cd "$OUT" && shasum -a 256 "$FINAL" > "$FINAL.sha256")
  for extra in Roadie.app.dSYM.zip dsym-uuids.txt; do
    if [[ -f "${ZIP:h}/$extra" ]]; then cp "${ZIP:h}/$extra" "$OUT/"; fi
  done
fi

print "==> DMG  $DMG"
print "==> Version $VERSION ($BUILD)${COMMIT:+, commit $COMMIT}"
print "==> Signed by $IDENTITY$([[ -n "$NOTARY_PROFILE" ]] && print ', notarized and stapled' || print ', not notarized')"
[[ -z "$RELEASE" ]] || print "==> sha256 $(cut -d' ' -f1 "$DMG.sha256")"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /' || true
