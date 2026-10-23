#!/bin/zsh
# Build a Sparkle appcast <item> from a finished DMG and prepend it to website/appcast.xml (#0161,
# docs/design/release.md §2.5 step 9, docs/website-hosting.md "Rules that keep updates working").
#
# usage: scripts/appcast-item.sh <dmg> --version X.Y.Z [--appcast website/appcast.xml]
#                                [--sign-update path] [--description file.html] [--dry-run [--signature-stub]]
#
#   - mounts the DMG read-only and reads CFBundleShortVersionString / CFBundleVersion from the app inside;
#     the short version must equal --version;
#   - runs `sign_update --account Roadie <dmg>` (default build/sparkle/bin/sign_update; the key comes from the
#     login keychain, never -s or --ed-key-file) and checks its length equals the DMG's byte size;
#   - the <description> is build/release/X.Y.Z/appcast-description.html from render-changelog.py when present;
#   - inserts the item before the first <item> (or before </channel>), then runs xmllint --noout.
# --dry-run prints the item and edits nothing; --signature-stub (dry-run only) skips sign_update.
set -euo pipefail
ROOT=${0:A:h:h}
dmg="" version="" appcast="$ROOT/website/appcast.xml" sign_update="$ROOT/build/sparkle/bin/sign_update"
description="" dry_run=0 stub=0
die() { print -u2 "appcast-item: $*"; exit 1 }
while (( $# )); do
  case $1 in
    --version) version=$2; shift 2 ;;
    --appcast) appcast=$2; shift 2 ;;
    --sign-update) sign_update=$2; shift 2 ;;
    --description) description=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --signature-stub) stub=1; shift ;;
    -*) die "unknown option $1" ;;
    *) [[ -z $dmg ]] || die "one DMG only"; dmg=$1; shift ;;
  esac
done
[[ -f $dmg ]] || die "no DMG given or not found: $dmg"
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "--version X.Y.Z is required"
(( stub && ! dry_run )) && die "--signature-stub needs --dry-run"
[[ -z $description ]] && description="$ROOT/build/release/$version/appcast-description.html"

# Read both versions from the app inside the read-only mount.
mnt=$(mktemp -d "${TMPDIR:-/tmp}/appcast-item.XXXXXX")
cleanup() { hdiutil detach -quiet "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true }
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null || die "can't mount $dmg"
apps=("$mnt"/*.app(N))
(( ${#apps} == 1 )) || die "expected one .app in the DMG, found ${#apps}"
plist="${apps[1]}/Contents/Info.plist"
short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
cleanup; trap - EXIT
[[ $short == $version ]] || die "the app says $short, not $version"
[[ $build =~ '^[0-9]{8}\.[0-9]{4}$' ]] || die "CFBundleVersion '$build' isn't a YYYYMMDD.HHMM build number"

size=$(stat -f %z "$dmg")
if (( stub )); then
  sig="STUB-SIGNATURE" length=$size
else
  [[ -x $sign_update ]] || die "sign_update not found at $sign_update"
  out=$("$sign_update" --account Roadie "$dmg") || die "sign_update failed"
  sig=$(print -r -- "$out" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')
  length=$(print -r -- "$out" | sed -nE 's/.*length="([0-9]+)".*/\1/p')
  [[ -n $sig && -n $length ]] || die "couldn't parse sign_update output"
fi
(( length == size )) || die "sign_update length $length != DMG size $size"

anchor="v${version//./-}"
pubdate=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
desc=""
if [[ -f $description ]]; then
  body=$(<"$description")
  [[ $body == *']]>'* ]] && die "$description contains ]]>"
  desc="      <description><![CDATA[
$body
      ]]></description>
"
fi
item="    <item>
      <title>Version $version</title>
      <pubDate>$pubdate</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$short</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://roadie.sstools.co/changelog.html#$anchor</sparkle:releaseNotesLink>
${desc}      <enclosure url=\"https://roadie.sstools.co/downloads/Roadie-$version.dmg\" length=\"$length\" type=\"application/octet-stream\" sparkle:edSignature=\"$sig\"/>
    </item>"

if (( dry_run )); then
  print -r -- "$item"
  exit 0
fi

[[ -f $appcast ]] || die "no appcast at $appcast"
grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$appcast" && die "$appcast already lists $version"
ITEM=$item python3 - "$appcast" <<'PY'
import os, sys
path, item = sys.argv[1], os.environ["ITEM"]
text = open(path, encoding="utf-8").read()
i = text.find("<item>")
if i < 0:
    i = text.find("</channel>")
    if i < 0:
        sys.exit("appcast-item: no </channel> in " + path)
i = text.rfind("\n", 0, i) + 1
open(path, "w", encoding="utf-8").write(text[:i] + item + "\n" + text[i:])
PY
xmllint --noout "$appcast" || die "$appcast is not valid XML"
print "appcast-item: added $version (build $build, $length bytes) to $appcast"
