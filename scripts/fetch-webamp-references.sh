#!/bin/zsh
# fetch-webamp-references.sh -- download the Winamp Skin Museum's public Webamp screenshots for a folder of skins.
#
# Usage: scripts/fetch-webamp-references.sh <skins-dir> [out-dir]     (out-dir defaults to build/webamp-reference)
#
# Host only, one time (the Tart guest has no network). For each *.wsz in <skins-dir> (read only, never modified)
# it computes the file's md5 and fetches https://r2.webampskins.org/screenshots/<md5>.png to
# <out-dir>/<basename>.png, appending `name<TAB>md5<TAB>fetched|missing` to <out-dir>/manifest.tsv. A re-zipped or
# edited skin has a different md5 and is recorded as missing ("no reference"). Only public PNGs are downloaded:
# nothing is uploaded and no credentials are involved. run-tests-vm.sh never calls this; it carries <out-dir> into
# the guest with --references. The output is gitignored (build/) and must never be committed.

set -euo pipefail

[[ $# -ge 1 && -d "$1" ]] || { print -r -- "usage: $0 <skins-dir> [out-dir]" >&2; exit 2 }
SKINS_DIR=$1
OUT_DIR=${2:-"$(cd "$(dirname "$0")/.." && pwd)/build/webamp-reference"}
BASE_URL="https://r2.webampskins.org/screenshots"

mkdir -p "$OUT_DIR"
: > "$OUT_DIR/manifest.tsv"

fetched=0
missing=0
for skin in "$SKINS_DIR"/*.wsz(N); do
  name=${skin:t:r}
  md5=$(md5 -q "$skin")
  if curl -fsSL --retry 2 -o "$OUT_DIR/$name.png" "$BASE_URL/$md5.png" 2>/dev/null; then
    result=fetched
    (( fetched++ )) || true
  else
    rm -f "$OUT_DIR/$name.png"
    result=missing
    (( missing++ )) || true
  fi
  printf "%s\t%s\t%s\n" "$name" "$md5" "$result" >> "$OUT_DIR/manifest.tsv"
  print -r -- "$result  $name  ($md5)"
done
print -r -- "$fetched fetched, $missing missing -> $OUT_DIR"
