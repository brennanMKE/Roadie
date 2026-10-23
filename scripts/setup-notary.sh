#!/bin/zsh
# Store App Store Connect API credentials as a notarytool keychain profile.
# Usage: scripts/setup-notary.sh [--profile NAME] [--force]
set -euo pipefail
[[ -o xtrace ]] && { print -u2 "Refusing to run with xtrace on."; exit 1; }

profile="Roadie-notary"; force=0
while (( $# )); do
  case "$1" in
    --profile) profile="${2:?--profile needs a name}"; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help)
      print "Usage: $0 [--profile NAME] [--force]"
      print "Prompts for the .p8 path, key id and issuer id, then runs notarytool store-credentials (default profile Roadie-notary)."
      exit 0 ;;
    *) print -u2 "Unknown argument: $1"; exit 2 ;;
  esac
done

repo="${0:A:h:h}"
if (( ! force )) && xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  print "Profile '$profile' already works; nothing to do (use --force to replace it)."
  exit 0
fi

read -r "p8?Path to App Store Connect API key (.p8): "
p8="${~p8}"
[[ -f "$p8" ]] || { print -u2 "Not a file: $p8"; exit 1; }
p8="${p8:A}"
if [[ "$p8" == "$repo"/* ]]; then print -u2 "The .p8 must live outside the repo."; exit 1; fi
read -r "keyid?Key ID: "
read -r "issuer?Issuer ID: "
[[ -n "$keyid" && -n "$issuer" ]] || { print -u2 "Key ID and issuer ID are required."; exit 1; }

xcrun notarytool store-credentials "$profile" --key "$p8" --key-id "$keyid" --issuer "$issuer"
print "Stored profile '$profile'. Check: xcrun notarytool history --keychain-profile $profile"
