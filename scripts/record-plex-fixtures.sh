#!/bin/zsh
# Records PlexKit's test fixtures from the dev server and scrubs them. Host only, network only.
# The token lives only in $T for the duration of this script. It is never echoed or written.
set -euo pipefail
set +o xtrace
T=$(ssh joe 'defaults read com.plexapp.plexmediaserver PlexOnlineToken')
P="${PLEX_URL:-http://joe:32400}"
F="$(dirname "$0")/../Packages/PlayerKit/Sources/PlexKitStub/Fixtures"
mkdir -p "$F"

SCRUB='
  (.. | objects | select(has("machineIdentifier")) | .machineIdentifier) |= "0123456789abcdef0123456789abcdef01234567"
  | (.. | objects | select(has("uuid")) | .uuid) |= "00000000-0000-0000-0000-000000000000"
  | (.. | objects | select(has("librarySectionUUID")) | .librarySectionUUID) |= "00000000-0000-0000-0000-000000000000"
  | (.. | objects | select(has("file")) | .file) |= "/Media/Music/scrubbed"
  | (.. | objects | select(has("summary")) | .summary) |= .[0:160]
  | del(.. | objects | .Location?)
'

rec() {  # rec <name> <path> <start> <size> [curl args...]
  local name=$1 urlpath=$2 start=$3 size=$4
  shift 4
  # The token goes in on stdin (-H @-), not argv, so it never shows in the process list.
  print -r -- "X-Plex-Token: $T" | curl -sfS -G -H @- -H "Accept: application/json" \
       -H "X-Plex-Container-Start: $start" -H "X-Plex-Container-Size: $size" \
       "$@" "$P$urlpath" | jq "$SCRUB" > "$F/$name.json"
}

rec identity /identity 0 3
rec sections /library/sections 0 3
SEC=$(jq -r '.MediaContainer.Directory[] | select(.type == "artist") | .key' "$F/sections.json" | head -1)
rec artists-page "/library/sections/$SEC/all" 0 3 --data-urlencode type=8
rec albums-page  "/library/sections/$SEC/all" 0 3 --data-urlencode type=9
rec tracks-page  "/library/sections/$SEC/all" 0 3 --data-urlencode type=10
TOTAL=$(jq '.MediaContainer.totalSize' "$F/tracks-page.json")
rec tracks-last-page "/library/sections/$SEC/all" $((TOTAL - 1)) 3 --data-urlencode type=10
ARTIST=$(jq -r '.MediaContainer.Metadata[0].ratingKey' "$F/artists-page.json")
rec artist-children "/library/metadata/$ARTIST/children" 0 3
ALBUM=$(jq -r '.MediaContainer.Metadata[0].ratingKey' "$F/artist-children.json")
rec album-children "/library/metadata/$ALBUM/children" 0 3
WORD=$(jq -r '.MediaContainer.Metadata[0].title | split(" ")[0]' "$F/tracks-page.json")
rec tracks-search "/library/sections/$SEC/all" 0 3 --data-urlencode type=10 --data-urlencode "title=$WORD"

# Scrub check: the token must not be in any fixture, and nothing may look like one.
if grep -rqF -- "$T" "$F"; then print -u2 "!! token found in fixtures -- NOT committing"; exit 1; fi
if grep -rqiE 'X-Plex-Token|authToken' "$F"; then print -u2 "!! token-like field in fixtures"; exit 1; fi
print "Recorded $(ls "$F" | wc -l | tr -d ' ') fixtures into $F ($(du -sh "$F" | cut -f1))"
