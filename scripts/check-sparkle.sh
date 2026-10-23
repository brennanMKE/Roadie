#!/bin/zsh
# check-sparkle.sh — assert the built app embeds Sparkle correctly and only the app links it (#0158, docs/sparkle.md).
# Checks Contents/Frameworks/Sparkle.framework with Autoupdate, Updater.app and both XPC services; that the app links
# Sparkle and the Quick Look appexes don't (otool -L); and that the sandbox-only mach-lookup entitlements (-spks/-spki)
# are absent. Reads only; runs in the guest against a built Roadie.app (the VM step app-sparkle, on the Release build).
# Usage: scripts/check-sparkle.sh <path/to/Roadie.app>
set -uo pipefail
app=${1:?usage: check-sparkle.sh <Roadie.app>}
failures=0
ok()  { print -r -- "sparkle: $1 ok"; }
bad() { print -r -- "sparkle: $1 FAIL ${2:-}"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi }
links_sparkle() { otool -L "$1" 2>/dev/null | grep -q 'Sparkle.framework'; }

fw=$app/Contents/Frameworks/Sparkle.framework
cur=$fw/Versions/Current
check framework        test -d "$fw"
check autoupdate       test -x "$cur/Autoupdate"
check updater-app      test -d "$cur/Updater.app"
check installer-xpc    test -d "$cur/XPCServices/Installer.xpc"
check downloader-xpc   test -d "$cur/XPCServices/Downloader.xpc"
check app-links        links_sparkle "$app/Contents/MacOS/Roadie"

for appex in "$app"/Contents/PlugIns/*.appex(N); do
  name=${${appex:t}%.appex}
  if links_sparkle "$appex/Contents/MacOS/$name"; then bad "appex-$name-free" "(links Sparkle)"; else ok "appex-$name-free"; fi
done

ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
if [[ "$ents" == *-spks* || "$ents" == *-spki* ]]; then bad no-spks-spki "(sandbox-only entitlements present)"
else ok no-spks-spki; fi

(( failures == 0 )) || { print -u2 -r -- "!! $failures Sparkle check(s) failed"; exit 1; }
print -r -- "Sparkle OK: $app"
