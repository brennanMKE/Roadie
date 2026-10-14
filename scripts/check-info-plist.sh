#!/bin/zsh
# check-info-plist.sh — assert the app's Info.plist carries the networking keys (#0012)
# and still carries the .wsz type (#0047) and claims it as a document type (#0043). Reads only; runs on the host against the
# regenerated App/Info.plist and in the guest against the built SkinAmp.app.
# Usage: scripts/check-info-plist.sh <path/to/Info.plist>
set -euo pipefail
P=${1:?usage: check-info-plist.sh <Info.plist>}
get()    { plutil -extract "$1" raw -o - "$P" 2>/dev/null; }
expect() { local got; got="$(get "$1" || true)"; print -r -- "$1 = ${got:-<absent>}"
           [[ "$got" == "$2" ]] || { print -u2 -r -- "!! $1: expected '$2'"; return 1; }; }
absent() { if get "$1" >/dev/null; then print -u2 -r -- "!! $1 must be absent"; return 1; fi
           print -r -- "$1 absent (ok)"; }

# -expect bool fails if the value was emitted as a string (ATS would ignore "true").
plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw -expect bool -o - "$P" >/dev/null
expect NSAppTransportSecurity.NSAllowsLocalNetworking true
absent NSAppTransportSecurity.NSAllowsArbitraryLoads
absent NSAppTransportSecurity.NSExceptionDomains
absent NSBonjourServices
desc="$(get NSLocalNetworkUsageDescription || true)"
print -r -- "NSLocalNetworkUsageDescription = ${desc:-<absent>}"
[[ "$desc" == *Plex* ]] || { print -u2 "!! NSLocalNetworkUsageDescription is missing or does not mention Plex"; exit 1; }
expect UTExportedTypeDeclarations.0.UTTypeIdentifier com.brennanmke.skinamp.wsz
expect CFBundleDocumentTypes.0.LSItemContentTypes.0 com.brennanmke.skinamp.wsz
print -r -- "Info.plist OK: $P"
