#!/bin/zsh
# check-entitlements.sh — assert the built app is signed with the Location entitlement (#0075). Under the hardened
# runtime, Location Services (and so the Wi-Fi network name) is denied silently without it. Reads only; runs in the
# guest against the built SkinAmp.app.
# Usage: scripts/check-entitlements.sh <path/to/SkinAmp.app>
set -euo pipefail
APP=${1:?usage: check-entitlements.sh <SkinAmp.app>}
ents="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
key=com.apple.security.personal-information.location
if [[ "$ents" == *"<key>$key</key><true/>"* || "$ents" == *"<key>$key</key>"*"<true/>"* ]]; then
  print -r -- "$key = true"
else
  print -u2 -r -- "!! $key missing from the code signature"; exit 1
fi
print -r -- "Entitlements OK: $APP"
