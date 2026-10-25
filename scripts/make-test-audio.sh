#!/bin/zsh
# make-test-audio.sh — regenerate the committed audio fixtures (#0195, docs/design/test-automation.md §2.3).
# Host only, run once; the tests never call it. Writes Packages/PlayerKit/Sources/PlayerKitTestFixtures/Audio/:
#   01 Tone A.mp3, 02 Tone B.mp3   lame -b 64 at 44.1 kHz, ID3v2 tags, 2.5 s, 440 / 660 Hz (skipped when lame isn't installed)
#   03 Tone C.m4a                  AAC 96 kbps (afconvert), iTunes tags, 2.0 s, 880 Hz
#   04 Tone D.m4a                  ALAC (afconvert), iTunes tags, 0.75 s, 1100 Hz
#   05 Tone E.flac                 FLAC (afconvert), Vorbis comments (scripts/flac-tag.py), 0.75 s, 1320 Hz
#   06 Tone F.wav                  16-bit PCM, untagged, 0.5 s, 1760 Hz
#   cover.jpg                      64 px
#   MANIFEST.txt                   md5, nominal duration and format of each file, plus the tool versions
# Encoders aren't deterministic (AAC, lame's header), so an existing file is kept unless --force is given; the
# manifest always records the md5 of the file that is there. Fails if any file is over 150 KB.
# Usage: scripts/make-test-audio.sh [--force]
set -euo pipefail
cd "${0:A:h}/.."

force=0
[[ ${1:-} == --force ]] && force=1
out=Packages/PlayerKit/Sources/PlayerKitTestFixtures/Audio
mkdir -p $out
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

artist="Tone Artist"
album="Tone Album"
year=2026

tone() { swift scripts/make-test-tone.swift "$@" }

# place <name>: move $tmp/<name> into the fixture folder unless it's there already (or --force).
place() {
  if [[ -e "$out/$1" && $force == 0 ]]; then
    print -r -- "kept     $1 (use --force to replace)"
  else
    mv "$tmp/$1" "$out/$1"
    print -r -- "wrote    $1"
  fi
}

# MP3s
if command -v lame >/dev/null; then
  for spec in "01 Tone A.mp3:Tone A:440:1" "02 Tone B.mp3:Tone B:660:2"; do
    IFS=: read -r name title hz track <<< "$spec"
    tone "$tmp/src.wav" $hz 2.5
    lame --quiet -b 64 --resample 44.1 --id3v2-only --tt "$title" --ta "$artist" --tl "$album" --tn $track --ty $year \
      "$tmp/src.wav" "$tmp/$name"
    place "$name"
  done
else
  print -r -- "lame not installed (brew install lame); mp3 fixtures unchanged"
fi

# AAC and ALAC
tone "$tmp/c.wav" 880 2.0
afconvert -f m4af -d aac -b 96000 "$tmp/c.wav" "$tmp/c-raw.m4a"
tone --tag "$tmp/c-raw.m4a" "$tmp/03 Tone C.m4a" "Tone C" "$artist" "$album" 3 $year
place "03 Tone C.m4a"

tone "$tmp/d.wav" 1100 0.75
afconvert -f m4af -d alac "$tmp/d.wav" "$tmp/d-raw.m4a"
tone --tag "$tmp/d-raw.m4a" "$tmp/04 Tone D.m4a" "Tone D" "$artist" "$album" 4 $year
place "04 Tone D.m4a"

# FLAC
tone "$tmp/e.wav" 1320 0.75
afconvert -f flac -d flac "$tmp/e.wav" "$tmp/05 Tone E.flac"
python3 -I scripts/flac-tag.py "$tmp/05 Tone E.flac" "TITLE=Tone E" "ARTIST=$artist" "ALBUM=$album" TRACKNUMBER=5 DATE=$year
place "05 Tone E.flac"

# WAV and cover
tone "$tmp/06 Tone F.wav" 1760 0.5
place "06 Tone F.wav"
tone --jpeg "$tmp/cover.jpg" 64
place "cover.jpg"

# Size limit
for f in $out/*(.); do
  size=$(stat -f %z "$f")
  if (( size > 150000 )); then print -u2 -r -- "!! ${f:t} is $size bytes (limit 150000)"; exit 1; fi
done

# Manifest: name, md5, nominal seconds, format (tab separated). Tests and check-fixtures.sh read it.
lame_version=$( (command -v lame >/dev/null && lame --version 2>/dev/null | head -1) || print "lame not installed")
{
  print -r -- "# Audio fixtures for #0195. Regenerate with scripts/make-test-audio.sh [--force]; checked by scripts/check-fixtures.sh."
  print -r -- "# macOS $(sw_vers -productVersion); $(swift --version 2>/dev/null | head -1); $lame_version"
  print -r -- "# name	md5	seconds	format"
  for spec in "01 Tone A.mp3:2.5:mp3 64 kbps 440 Hz" "02 Tone B.mp3:2.5:mp3 64 kbps 660 Hz" \
              "03 Tone C.m4a:2.0:aac 96 kbps 880 Hz" "04 Tone D.m4a:0.75:alac 1100 Hz" \
              "05 Tone E.flac:0.75:flac 1320 Hz" "06 Tone F.wav:0.5:pcm 16-bit 1760 Hz" "cover.jpg:0:jpeg 64 px"; do
    IFS=: read -r name seconds format <<< "$spec"
    [[ -e "$out/$name" ]] || continue
    print -r -- "$name	$(md5 -q "$out/$name")	$seconds	$format"
  done
} > $out/MANIFEST.txt
print -r -- "wrote    MANIFEST.txt ($(du -sk $out | cut -f1) KB total)"
