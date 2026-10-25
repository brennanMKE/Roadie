#!/bin/zsh
# check-fixtures.sh — the committed audio stays small and in its place (#0195, docs/design/test-automation.md §2.3).
# Fails if any .mp3/.m4a/.flac/.wav is tracked outside Packages/PlayerKit/Sources/PlayerKitTestFixtures/Audio/ and
# Packages/*/Tests/**/Fixtures/, if any file in those folders is over 200 KB, or if MANIFEST.txt's md5s don't match.
# Uses `git ls-files` on the host; the guest has no git, so there it lists the exported tree with find instead. That
# find skips the top-level TestMusic/ and TestSkins/, which run-tests-vm.sh --ui generates into the export at run time
# (make-test-library.sh, the skins cache) and which are never committed; on the host, git ls-files still flags them.
# Usage: scripts/check-fixtures.sh
set -euo pipefail
cd "${0:A:h}/.."

audio_dir=Packages/PlayerKit/Sources/PlayerKitTestFixtures/Audio
if command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files=("${(@f)$(git ls-files)}")
  source_note="git ls-files"
else
  files=("${(@f)$(find . \( -path ./TestMusic -o -path ./TestSkins -o -name .build -o -name build -o -name .git -o -name References -o -name Skins \) -prune -o -type f -print | sed 's#^\./##')}")
  source_note="find (no git)"
fi

allowed() {
  [[ $1 == $audio_dir/* ]] && return 0
  [[ $1 == Packages/*/Tests/*/Fixtures/* || $1 == Packages/*/Tests/**/Fixtures/* ]] && return 0
  return 1
}

bad=0
for f in $files; do
  [[ -n $f ]] || continue
  case ${f:l} in
    *.mp3|*.m4a|*.flac|*.wav)
      if ! allowed "$f"; then print -u2 -r -- "!! audio outside the fixture folders: $f"; bad=$((bad + 1)); fi ;;
  esac
  if allowed "$f" && [[ -f $f ]]; then
    size=$(stat -f %z "$f")
    if (( size > 200000 )); then print -u2 -r -- "!! $f is $size bytes (limit 200000)"; bad=$((bad + 1)); fi
  fi
done

manifest=$audio_dir/MANIFEST.txt
if [[ ! -f $manifest ]]; then
  print -u2 -r -- "!! $manifest is missing"; bad=$((bad + 1))
else
  checked=0
  while IFS=$'\t' read -r name md5 seconds format; do
    [[ -z $name || $name == \#* ]] && continue
    if [[ ! -f $audio_dir/$name ]]; then
      print -u2 -r -- "!! MANIFEST lists $name but it isn't there"; bad=$((bad + 1)); continue
    fi
    actual=$(md5 -q "$audio_dir/$name")
    if [[ $actual != $md5 ]]; then
      print -u2 -r -- "!! $name md5 $actual, MANIFEST says $md5 (rerun scripts/make-test-audio.sh)"; bad=$((bad + 1))
    fi
    checked=$((checked + 1))
  done < $manifest
  (( checked > 0 )) || { print -u2 -r -- "!! MANIFEST lists no files"; bad=$((bad + 1)) }
fi

if (( bad )); then print -u2 -r -- "!! $bad fixture problem(s)"; exit 1; fi
print -r -- "fixtures OK ($source_note): audio only in the fixture folders, all under 200 KB, MANIFEST md5s match ($checked files)"
