#!/bin/zsh
# make-dmg.sh — sign a Release SkinAmp.app with Developer ID and package it as a DMG, on the host.
#
# The app is never built here: scripts/verify.sh --head --dmg builds it in the VM and brings it back as
# build/vm-tests/<run-id>/release/SkinAmp.app.zip. This script only re-signs and packages; it never launches the app.
#
# Usage: scripts/make-dmg.sh SkinAmp.app.zip [--identity NAME] [--notary-profile PROFILE]
#   --identity NAME          codesign identity (default: the first "Developer ID Application" in the keychain)
#   --notary-profile PROFILE notarize and staple with this `xcrun notarytool store-credentials` profile;
#                            without it the DMG is signed but not notarized, and Gatekeeper asks once on first open
# Output: build/dist/SkinAmp-<version>-<build>-<commit>.dmg (the commit comes from the run's commit.txt when present)

set -euo pipefail

REPO=${0:A:h:h}
ZIP=""
IDENTITY=""
NOTARY_PROFILE=""
while (( $# )); do
  case $1 in
    --identity) IDENTITY=$2; shift 2 ;;
    --notary-profile) NOTARY_PROFILE=$2; shift 2 ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) [[ -z "$ZIP" ]] || { print -u2 "make-dmg.sh: one zip only"; exit 2 }; ZIP=${1:A}; shift ;;
  esac
done
[[ -f "$ZIP" ]] || { print -u2 "make-dmg.sh: give the SkinAmp.app.zip from scripts/verify.sh --head --dmg"; exit 2 }
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  [[ -n "$IDENTITY" ]] || { print -u2 "make-dmg.sh: no Developer ID Application identity; pass --identity"; exit 1 }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/skinamp-dmg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK/stage"
APP="$WORK/stage/SkinAmp.app"
[[ -d "$APP" ]] || { print -u2 "make-dmg.sh: no SkinAmp.app in $ZIP"; exit 1 }

# Re-sign inside out with the hardened runtime, keeping each bundle's own entitlements (minus get-task-allow,
# which notarization rejects). Nested code first: frameworks, dylibs, then the Quick Look extensions, then the app.
sign() {
  local target=$1 ents="$WORK/ents-${RANDOM}.plist"
  codesign -d --entitlements - --xml "$target" >"$ents" 2>/dev/null || true
  if [[ -s "$ents" ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ents" >/dev/null 2>&1 || true
    codesign --force --timestamp --options runtime --entitlements "$ents" --sign "$IDENTITY" "$target"
  else
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$target"
  fi
}
for f in "$APP"/Contents/Frameworks/*.(framework|dylib)(N) "$APP"/Contents/PlugIns/*.appex(N) "$APP"/Contents/Extensions/*.appex(N); do
  sign "$f"
done
sign "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
COMMIT=$(cat "${ZIP:h:h}/commit.txt" 2>/dev/null || true)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
NAME="SkinAmp-$VERSION-$BUILD${COMMIT:+-$COMMIT}"
mkdir -p "$REPO/build/dist"
DMG="$REPO/build/dist/$NAME.dmg"

ln -s /Applications "$WORK/stage/Applications"
hdiutil create -quiet -volname SkinAmp -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

print "==> DMG  $DMG"
print "==> Version $VERSION ($BUILD)${COMMIT:+, commit $COMMIT}"
print "==> Signed by $IDENTITY$([[ -n "$NOTARY_PROFILE" ]] && print ', notarized and stapled' || print ', not notarized')"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /' || true
