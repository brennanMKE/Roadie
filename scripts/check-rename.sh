#!/bin/zsh
# check-rename.sh — Gate A's rename check (docs/design/release.md §2.1, #0156). Lists every tracked `SkinAmp`
# (case-insensitive) or `com\.brennanmke` outside issues/NNNN.md and exits 1 if one is not in the allowlist below.
# Reads only. Uses git grep, so it runs on the host against the committed tree plus the working tree; it is not a VM
# step. Usage: scripts/check-rename.sh
set -euo pipefail
cd "${0:A:h}/.."

# Whole files whose hits are history, recordings or another project's identity.
allow_files=(
  'scripts/check-rename.sh'
  'docs/design/release.md'                 # the rename plan itself
  'docs/plex-music-library.md'             # historical (#0074)
  'winamp-skin-player-brief.md'            # the original brief
  'docs/ma-protocol/sendspin-probe.json'   # recorded probe session (#0066)
  'Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures/players-all-sendspin.json'              # recorded
  'Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures/players-all-sendspin-unavailable.json'  # recorded
  'Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures/error-unknown-player.json'              # recorded
  'Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures/error-unknown-command.json'             # recorded
  'Packages/PlayerKit/Tests/SendspinKitTests/Fixtures/sendspin-legacy-session.json'                  # recorded
  'Spikes/AirPlaySpike/*'                  # throwaway spike with its own AirPlaySpike bundle id (#0050)
  'docs/airplay-spike-results.md'          # that spike's log subsystem
)

# path:regex pairs; a hit is allowed when its file equals the path and its line matches the regex.
allow_lines=(
  'App/LegacyDataCleanup.swift:keychainService = "com\.brennanmke\.SkinAmp\.plex"'
  'scripts/check-identifiers.sh:com\.brennanmke|SkinAmp'
  'README.md:The project was called SkinAmp during development\.'
  'docs/website-hosting.md:`SkinAmp` to `Roadie`|brennanMKE/SkinAmp'
  'docs/sendspin-notes.md:skinamp-probe|SkinAmp probe|"(product_name|manufacturer)": "SkinAmp"'
)

bad=0
while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; text=${rest#*:}
  ok=0
  for pat in $allow_files; do [[ $file == ${~pat} ]] && { ok=1; break; }; done
  if (( ! ok )); then
    for entry in $allow_lines; do
      [[ $file == ${entry%%:*} ]] || continue
      if print -r -- "$text" | grep -Eq -- "${entry#*:}"; then ok=1; break; fi
    done
  fi
  if (( ! ok )); then print -u2 -r -- "!! $hit"; bad=$((bad + 1)); fi
done < <(git grep -nIi -E 'skinamp|com\.brennanmke' -- ':!issues/[0-9][0-9][0-9][0-9].md' || true)

if (( bad )); then print -u2 -r -- "!! $bad old-name hit(s) outside the rename allowlist"; exit 1; fi
print -r -- "rename OK: old names only in the allowlist"
