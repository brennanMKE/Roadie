#!/bin/zsh
# Import release credentials written by export-release-credentials.sh, skipping anything already present.
# Usage: scripts/import-release-credentials.sh [--sparkle-bin DIR] SRC_DIR
set -euo pipefail
[[ -o xtrace ]] && { print -u2 "Refusing to run with xtrace on."; exit 1; }

repo="${0:A:h:h}"
sparkle_bin="$repo/build/sparkle/bin"; src=""
usage="Usage: $0 [--sparkle-bin DIR] SRC_DIR"
while (( $# )); do
  case "$1" in
    --sparkle-bin) sparkle_bin="${2:?--sparkle-bin needs a directory}"; shift 2 ;;
    -h|--help)
      print "$usage"
      print "Imports sparkle-roadie.key and DeveloperID.p12 when present; never replaces an existing key or identity."
      exit 0 ;;
    -*) print -u2 "Unknown option: $1"; exit 2 ;;
    *) src="$1"; shift ;;
  esac
done
[[ -n "$src" && -d "$src" ]] || { print -u2 "$usage"; exit 2; }
src="${src:A}"

# Sparkle key: check for an existing one (-p) before ever importing (-f).
key="$src/sparkle-roadie.key"
if [[ -f "$key" ]]; then
  gk="$sparkle_bin/generate_keys"
  [[ -x "$gk" ]] || { print -u2 "generate_keys not found in $sparkle_bin (use --sparkle-bin)."; exit 1; }
  if "$gk" --account Roadie -p >/dev/null 2>&1; then
    print "Sparkle key for account Roadie is already in the keychain; skipped."
  else
    "$gk" --account Roadie -f "$key"
    print "Imported the Sparkle key."
  fi
else
  print "No sparkle-roadie.key in $src; skipped."
fi

# Developer ID identity.
p12="$src/DeveloperID.p12"
if [[ -f "$p12" ]]; then
  if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    print "A Developer ID Application identity is already present; skipped."
  else
    print "Importing DeveloperID.p12; security will ask for its passphrase."
    security import "$p12" -f pkcs12 -T /usr/bin/codesign
  fi
else
  print "No DeveloperID.p12 in $src; skipped."
fi

p8s=("$src"/*.p8(N))
if (( ${#p8s} )); then
  print "Found ${p8s[1]:t}: move it to ~/.appstoreconnect/ (mode 600), then run scripts/setup-notary.sh."
fi

if [[ -x "$repo/scripts/preflight.sh" ]]; then
  "$repo/scripts/preflight.sh" --credentials-only
else
  print "Run scripts/preflight.sh --credentials-only to check this Mac."
fi
