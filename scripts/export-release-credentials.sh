#!/bin/zsh
# Export release credentials (Sparkle key, Developer ID .p12, optional .p8) to a directory outside the repo.
# Usage: scripts/export-release-credentials.sh [--sparkle-bin DIR] [--p8 PATH] DEST_DIR
set -euo pipefail
[[ -o xtrace ]] && { print -u2 "Refusing to run with xtrace on."; exit 1; }

repo="${0:A:h:h}"
sparkle_bin="$repo/build/sparkle/bin"; p8=""; dest=""
usage="Usage: $0 [--sparkle-bin DIR] [--p8 PATH] DEST_DIR"
while (( $# )); do
  case "$1" in
    --sparkle-bin) sparkle_bin="${2:?--sparkle-bin needs a directory}"; shift 2 ;;
    --p8) p8="${2:?--p8 needs a path}"; shift 2 ;;
    -h|--help)
      print "$usage"
      print "Exports sparkle-roadie.key, DeveloperID.p12 and (with --p8) the API key. DEST_DIR must be outside the repo and empty."
      exit 0 ;;
    -*) print -u2 "Unknown option: $1"; exit 2 ;;
    *) [[ -z "$dest" ]] || { print -u2 "$usage"; exit 2; }; dest="$1"; shift ;;
  esac
done
[[ -n "$dest" ]] || { print -u2 "$usage"; exit 2; }

# Resolve real paths before creating anything.
repo_real="${repo:A}"
dest_real="${dest:A}"
if [[ "$dest_real" == "$repo_real" || "$dest_real" == "$repo_real"/* ]]; then
  print -u2 "Refusing: $dest_real is inside the repo."; exit 1
fi
if [[ -e "$dest_real" ]]; then
  [[ -d "$dest_real" ]] || { print -u2 "Refusing: $dest_real is not a directory."; exit 1; }
  [[ -z "$(ls -A "$dest_real")" ]] || { print -u2 "Refusing: $dest_real is not empty."; exit 1; }
fi

gk="$sparkle_bin/generate_keys"
[[ -x "$gk" ]] || { print -u2 "generate_keys not found in $sparkle_bin (use --sparkle-bin)."; exit 1; }

umask 077
mkdir -p "$dest_real"
chmod 700 "$dest_real"

"$gk" --account Roadie -x "$dest_real/sparkle-roadie.key"
chmod 600 "$dest_real/sparkle-roadie.key"

print "Exporting identities; security will ask for an export passphrase."
security export -t identities -f pkcs12 -o "$dest_real/DeveloperID.p12"
chmod 600 "$dest_real/DeveloperID.p12"

if [[ -n "$p8" ]]; then
  cp "$p8" "$dest_real/${p8:t}"
  chmod 600 "$dest_real/${p8:t}"
fi

print ""
print "Exported to $dest_real:"
ls -l "$dest_real"
print "Move these into a password manager or an encrypted volume now, then delete $dest_real."

if [[ -x "$repo/scripts/preflight.sh" ]]; then
  "$repo/scripts/preflight.sh" --credentials-only
else
  print "Run scripts/preflight.sh --credentials-only to check this Mac."
fi
