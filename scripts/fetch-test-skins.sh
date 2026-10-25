#!/bin/zsh
# fetch-test-skins.sh -- download the UI tests' skins (scripts/test-skins.tsv) from the Winamp Skin Museum (#0198).
#
# Usage: scripts/fetch-test-skins.sh [--cache DIR] [--check] [--manifest FILE]
#
#   --cache DIR      where <name>.wsz files live (default ~/Library/Caches/co.sstools.roadie-test-skins; may be under
#                    build/, which is gitignored). Never inside the tracked repo: third-party skins are never committed.
#   --check          only report ok|missing|bad-md5 per row; exit 1 unless all ok. Never downloads.
#   --manifest FILE  default scripts/test-skins.tsv
#
# Host only (the Tart guest has no network); run-tests-vm.sh carries the cache into the export with --test-skins.
# The Museum is one person's hobby infrastructure: one request per skin, and a cached file with the right md5 is
# never re-downloaded. Downloads by md5 via fetch_skin_by_md5, falling back to r2.webampskins.org/skins/<md5>.wsz.

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HOME/Library/Caches/co.sstools.roadie-test-skins"
MANIFEST="$SCRIPTS/test-skins.tsv"
CHECK=0
while (( $# )); do
  case "$1" in
    --cache) CACHE=${2:-}; shift 2 2>/dev/null || { print -r -- "--cache needs a directory" >&2; exit 2 } ;;
    --manifest) MANIFEST=${2:-}; shift 2 2>/dev/null || { print -r -- "--manifest needs a file" >&2; exit 2 } ;;
    --check) CHECK=1; shift ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$CACHE" && -f "$MANIFEST" ]] || { print -r -- "usage: $0 [--cache DIR] [--check] [--manifest FILE]" >&2; exit 2 }

if (( CHECK )); then
  [[ -d "$CACHE" ]] || CACHE=/nonexistent-roadie-test-skins
  python3 -I "$SCRIPTS/test_skins.py" check "$MANIFEST" "$CACHE"
  exit $?
fi

rows=$(python3 -I "$SCRIPTS/test_skins.py" parse "$MANIFEST")
mkdir -p "$CACHE"
VERSION=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$SCRIPTS/../project.yml" 2>/dev/null || true)
UA="Roadie-tests/${VERSION:-0} (+https://roadie.sstools.co)"

cached=0 downloaded=0 failed=0 first=1
while IFS=$'\t' read -r name museum_id md5; do
  dest="$CACHE/$name.wsz"
  if [[ -f "$dest" && "$(md5 -q "$dest")" == "$md5" ]]; then
    print -r -- "ok (cached)  $name  ($museum_id $md5)"; (( cached++ )) || true; continue
  fi
  (( first )) || sleep 1
  first=0
  query="{\"query\":\"{ fetch_skin_by_md5(md5: \\\"$md5\\\") { download_url filename(normalize_extension: true, include_museum_id: true) nsfw } }\"}"
  url="" nsfw=""
  if resp=$(curl -fsS --retry 2 -A "$UA" -H 'Content-Type: application/json' -d "$query" https://skins.webamp.org/graphql 2>/dev/null); then
    parsed=$(print -r -- "$resp" | python3 -I -c '
import json, sys
s = (json.load(sys.stdin).get("data") or {}).get("fetch_skin_by_md5") or {}
print(s.get("download_url") or "")
print("true" if s.get("nsfw") else "false")' 2>/dev/null || true)
    url=${parsed%%$'\n'*}
    nsfw=${parsed##*$'\n'}
  fi
  if [[ "$nsfw" == true ]]; then
    print -r -- "FAIL nsfw  $name  ($museum_id $md5)"; (( failed++ )) || true; continue
  fi
  [[ -n "$url" ]] || url="https://r2.webampskins.org/skins/$md5.wsz"
  rm -f "$dest.part"
  if curl -fsSL --retry 2 -A "$UA" -o "$dest.part" "$url" && [[ "$(md5 -q "$dest.part")" == "$md5" ]]; then
    mv -f "$dest.part" "$dest"
    print -r -- "ok  $name  ($museum_id $md5)"; (( downloaded++ )) || true
  else
    rm -f "$dest.part"
    print -r -- "FAIL download or md5  $name  ($museum_id $md5)"; (( failed++ )) || true
  fi
done <<< "$rows"

print -r -- "$cached cached, $downloaded downloaded, $failed failed -> $CACHE"
(( failed == 0 ))
