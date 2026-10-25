#!/bin/zsh
# make-test-library.sh — lay the committed audio fixtures (#0195) out as an Artist/Album/Track music folder: two artists,
# three albums (one with two discs), one single in an artist folder, one M3U. The shell twin of
# AudioFixtures.makeLibrary(at:) for the guest (the UI tests' music folder); FolderBackendFixtureLibraryTests'
# makeLibraryMatchesTheScript keeps the two in step. Creates <out> if needed; refuses to overwrite files.
# Usage: scripts/make-test-library.sh <out>
set -euo pipefail
(( $# == 1 )) || { print -u2 "usage: scripts/make-test-library.sh <out>"; exit 2 }
src="${0:A:h}/../Packages/PlayerKit/Sources/PlayerKitTestFixtures/Audio"
out=$1

layout=(
  "Tone Artist/Tone Album/01 Tone A.mp3"        "01 Tone A.mp3"
  "Tone Artist/Tone Album/02 Tone B.mp3"        "02 Tone B.mp3"
  "Tone Artist/Tone Album/03 Tone C.m4a"        "03 Tone C.m4a"
  "Tone Artist/Tone Album/cover.jpg"            "cover.jpg"
  "Tone Artist/Two Discs/Disc 1/04 Tone D.m4a"  "04 Tone D.m4a"
  "Tone Artist/Two Discs/Disc 1/05 Tone E.flac" "05 Tone E.flac"
  "Tone Artist/Two Discs/Disc 2/06 Tone F.wav"  "06 Tone F.wav"
  "Other Artist/Single.m4a"                     "03 Tone C.m4a"
)

for target source in $layout; do
  mkdir -p "$out/${target:h}"
  cp -n "$src/$source" "$out/$target"
done

cat > "$out/Party.m3u" <<'EOF'
#EXTM3U
Tone Artist/Tone Album/01 Tone A.mp3
Tone Artist/Two Discs/Disc 2/06 Tone F.wav
Other Artist/Single.m4a
EOF
print -r -- "test library: $out (2 artists, 3 albums, 7 tracks, Party.m3u)"
