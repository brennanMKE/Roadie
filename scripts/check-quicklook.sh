#!/bin/zsh
# check-quicklook.sh — prove the Quick Look extensions work in the guest (#0043).
# Usage: scripts/check-quicklook.sh <SkinAmp.app> <outdir>
# Checks the embedded appexes (sandbox, extension points), registers them, generates test skins with
# scripts/make-test-skin.swift, and runs qlmanage -t / -p against them. Every assertion prints
# "quicklook: <name> ok|FAIL"; the exit status is non-zero if any failed. Guest-side only: it registers
# extensions with Launch Services and runs qlmanage, which must never happen on the host.
set -uo pipefail
app=${1:?usage: check-quicklook.sh <SkinAmp.app> <outdir>}
out=${2:?usage: check-quicklook.sh <SkinAmp.app> <outdir>}
app=${app:A}
mkdir -p "$out"; out=${out:A}
script_dir=${0:A:h}
failures=0
ok()   { print -r -- "quicklook: $1 ok"; }
bad()  { print -r -- "quicklook: $1 FAIL ${2:-}"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi }
# tmo SECONDS cmd...: run with a watchdog; a hung qlmanage must fail the check, not the whole run (exit 142 on timeout).
tmo() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"; }
plist() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

thumb=$app/Contents/PlugIns/SkinAmpThumbnail.appex
prev=$app/Contents/PlugIns/SkinAmpPreview.appex
crash_dir=$HOME/Library/Logs/DiagnosticReports
mkdir -p "$crash_dir"
before_crashes=$(ls "$crash_dir" 2>/dev/null | sort)

# 1. Bundle
check bundle-thumbnail-appex test -d "$thumb"
check bundle-preview-appex test -d "$prev"
check codesign-deep codesign --verify --deep --strict "$app"
for appex in $thumb $prev; do
  n=${appex:t:r}
  codesign -d --entitlements :- "$appex" > "$out/$n.entitlements.txt" 2>&1
  grep -A1 'com.apple.security.app-sandbox' "$out/$n.entitlements.txt" | grep -q '<true/>' && ok "$n sandboxed" || bad "$n sandboxed" "(see $n.entitlements.txt)"
  [[ "$(plist "$appex/Contents/Info.plist" NSExtension.NSExtensionAttributes.QLSupportedContentTypes.0)" == com.brennanmke.skinamp.wsz ]] && ok "$n content-type" || bad "$n content-type"
done
[[ "$(plist "$thumb/Contents/Info.plist" NSExtension.NSExtensionPointIdentifier)" == com.apple.quicklook.thumbnail ]] && ok thumbnail-extension-point || bad thumbnail-extension-point
[[ "$(plist "$prev/Contents/Info.plist" NSExtension.NSExtensionPointIdentifier)" == com.apple.quicklook.preview ]] && ok preview-extension-point || bad preview-extension-point
plutil -extract NSExtension.NSExtensionAttributes.QLIsDataBasedPreview raw -expect bool -o - "$prev/Contents/Info.plist" >/dev/null 2>&1 && ok preview-data-based || bad preview-data-based

# 2. Register
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" </dev/null >/dev/null 2>&1 || true
pluginkit -a "$thumb" </dev/null || true
pluginkit -a "$prev" || true
pluginkit -e use -i com.brennanmke.SkinAmp.Thumbnail || true
pluginkit -e use -i com.brennanmke.SkinAmp.Preview || true
sleep 2
pluginkit -m -v -i com.brennanmke.SkinAmp.Thumbnail > "$out/pluginkit-thumbnail.txt" 2>&1 || true
pluginkit -m -v -i com.brennanmke.SkinAmp.Preview > "$out/pluginkit-preview.txt" 2>&1 || true
pluginkit -m -v > "$out/pluginkit-all.txt" 2>&1 || true
grep -F com.brennanmke.SkinAmp.Thumbnail "$out/pluginkit-thumbnail.txt" | grep -qv '^-' && ok pluginkit-thumbnail || bad pluginkit-thumbnail "(see pluginkit-thumbnail.txt)"
grep -F com.brennanmke.SkinAmp.Preview "$out/pluginkit-preview.txt" | grep -qv '^-' && ok pluginkit-preview || bad pluginkit-preview "(see pluginkit-preview.txt)"

# 3. Fixtures
tmo 300 swift "$script_dir/make-test-skin.swift" "$out/test.wsz" </dev/null || bad make-test-skin
cp /etc/hosts "$out/bad.wsz"
( cd "$out" && printf '<skin/>' > skin.xml && rm -f modern.wsz && zip -q modern.wsz skin.xml && rm skin.xml )
sleep 1
ctype=$(mdls -name kMDItemContentType -raw "$out/test.wsz" 2>/dev/null)
print -r -- "quicklook: mdls content type = $ctype"
[[ "$ctype" == com.brennanmke.skinamp.wsz ]] && ok content-type-registered || bad content-type-registered "(got $ctype)"
# #0047: the open panel enables a file only when its type conforms to an allowed type (.zip), so check conformance.
ctree=$(mdls -name kMDItemContentTypeTree -raw "$out/test.wsz" 2>/dev/null)
[[ "$ctree" == *public.zip-archive* ]] && ok content-type-conforms-zip || bad content-type-conforms-zip "(tree: $ctree)"

# 4. Thumbnail. The public QLThumbnailGenerator API goes through the same extension Finder uses. (`qlmanage -t`
# hangs for extension-provided types in a headless guest -- "No sandbox token for thumbnail request" -- while it
# works for system types, so it is not used as the gate; see docs/testing-in-vm.md.)
tmo 30 qlmanage -r </dev/null >/dev/null 2>&1; print -r -- "quicklook: qlmanage -r exit $?"
tmo 30 qlmanage -r cache </dev/null >/dev/null 2>&1; print -r -- "quicklook: qlmanage -r cache exit $?"
magenta() { # png -> 0 if skin pixel (4,100) is magenta
  local rgba; rgba=$(tmo 300 swift "$script_dir/pixel-at.swift" "$1" 4 100 --of 275 116 2>&1)
  print -r -- "quicklook: $1:t sample (4,100) = $rgba"
  local r g b a; read r g b a <<< "$rgba"
  [[ "$r" == <-> && "$r" -ge 240 && "$g" -le 16 && "$b" -ge 240 ]]
}
for size in 512 64; do
  rm -f -- "$out/gen-$size.png"
  tmo 120 swift "$script_dir/ql-thumb.swift" "$out/test.wsz" $size "$out/gen-$size.png" </dev/null
  if [[ -f "$out/gen-$size.png" ]] && magenta "$out/gen-$size.png"; then ok "thumbnail-$size"; else bad "thumbnail-$size"; fi
done
for name in bad modern; do
  rm -f -- "$out/gen-$name.png"
  tmo 120 swift "$script_dir/ql-thumb.swift" "$out/$name.wsz" 512 "$out/gen-$name.png" </dev/null
  rc=$?
  if [[ -f "$out/gen-$name.png" ]]; then bad "thumbnail-$name-fallback" "(rendered a skin)"
  elif (( rc == 4 )); then ok "thumbnail-$name-fallback"   # generic icon, no crash
  else bad "thumbnail-$name-fallback" "(exit $rc)"; fi
done
# Informational only: qlmanage -t on the test skin, short watchdog.
tmo 20 qlmanage -t -s 512 -o "$out" "$out/test.wsz" </dev/null >"$out/qlmanage-t-512.log" 2>&1; print -r -- "quicklook: (info) qlmanage -t exit $?"
(( failures == 0 )) && print -r -- "quicklook: thumbnail ok"

# 5. Preview: the extension process must come alive and serve the page
for name in test bad; do
  tmo 30 qlmanage -p "$out/$name.wsz" </dev/null >"$out/qlmanage-p-$name.log" 2>&1 &
  qlpid=$!
  alive=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if pgrep -f SkinAmpPreview >/dev/null; then alive=1; break; fi
  done
  (( alive )) && ok "preview-$name" || bad "preview-$name" "(no SkinAmpPreview process)"
  kill $qlpid 2>/dev/null; pkill -f 'qlmanage -p' 2>/dev/null; sleep 1
done
(( failures == 0 )) && print -r -- "quicklook: preview ok"

# 6. No crashes
after_crashes=$(ls "$crash_dir" 2>/dev/null | sort)
new=$(comm -13 <(print -r -- "$before_crashes") <(print -r -- "$after_crashes") | grep -E '^SkinAmp' || true)
if [[ -n "$new" ]]; then
  bad crash-reports "($new)"
  for f in ${(f)new}; do cp "$crash_dir/$f" "$out/" 2>/dev/null; done
else ok no-crash-reports; fi
/usr/bin/log show --last 5m --predicate 'process BEGINSWITH "SkinAmp" OR subsystem == "com.apple.quicklook" OR process == "pkd"' > "$out/quicklook.log" 2>&1 || true

(( failures == 0 )) || { print -r -- "quicklook: $failures check(s) FAILED"; exit 1; }
print -r -- "quicklook: all checks passed"
