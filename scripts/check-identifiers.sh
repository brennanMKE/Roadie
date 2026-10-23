#!/bin/zsh
# check-identifiers.sh — after the identity switch to co.sstools.roadie (#0153, docs/design/release.md §2.1 W2), the only
# `com.brennanmke` left in the app, packages, Quick Look extensions, scripts and project.yml is the removed Plex
# source's Keychain service that LegacyDataCleanup deletes. Nobody else ran SkinAmp, so there is no migration and no
# transitional UTI. Reads only; plain grep, so it
# works in the guest without git. Exits 1 and lists any other match.
# Usage: scripts/check-identifiers.sh
set -euo pipefail
cd "${0:A:h}/.."

# path:regex pairs; a match is allowed when its file equals the path and its line matches the regex.
allow=(
  'App/LegacyDataCleanup.swift:keychainService = "com\.brennanmke\.SkinAmp\.plex"'
)

bad=0
while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; text=${rest#*:}
  [[ $file == scripts/check-identifiers.sh ]] && continue
  ok=0
  for entry in $allow; do
    [[ $file == ${entry%%:*} ]] || continue
    if print -r -- "$text" | grep -Eq -- "${entry#*:}"; then ok=1; break; fi
  done
  if (( ! ok )); then print -u2 -r -- "!! $hit"; bad=$((bad + 1)); fi
done < <(grep -rnI --exclude-dir=.build --exclude-dir=build -- 'com\.brennanmke' App Packages QuickLook scripts project.yml || true)

if (( bad )); then print -u2 -r -- "!! $bad com.brennanmke identifier(s) outside the legacy allowlist"; exit 1; fi
print -r -- "identifiers OK: com.brennanmke only in the legacy allowlist"
