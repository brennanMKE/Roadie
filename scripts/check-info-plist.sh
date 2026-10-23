#!/bin/zsh
# check-info-plist.sh — assert the app's Info.plist carries the networking keys (#0012, #0063), the location descriptions (#0075), NSBonjourServices (#0104)
# and still carries the .wsz type (#0047) and claims it as a document type (#0043). Reads only; runs on the host against the
# regenerated App/Info.plist and in the guest against the built Roadie.app.
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
# ATS stays at local-network exemption only (#0063): plain http/ws works for .local names, unqualified names and IP
# addresses; every other server (a public name, Tailscale MagicDNS) must use https/wss. Arbitrary loads and exception
# domains would widen that, and NSAllowsArbitraryLoads is ignored next to NSAllowsLocalNetworking anyway.
absent NSAppTransportSecurity.NSAllowsArbitraryLoads
absent NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent
absent NSAppTransportSecurity.NSAllowsArbitraryLoadsForMedia
absent NSAppTransportSecurity.NSExceptionDomains
# #0104: discovery browses exactly these three types.
expect NSBonjourServices.0 _home-assistant._tcp
expect NSBonjourServices.1 _music-assistant._tcp
expect NSBonjourServices.2 _sendspin-server._tcp
absent NSBonjourServices.3
desc="$(get NSLocalNetworkUsageDescription || true)"
print -r -- "NSLocalNetworkUsageDescription = ${desc:-<absent>}"
[[ "$desc" == *"Music Assistant"* && "$desc" != *Plex* ]] || {
  print -u2 "!! NSLocalNetworkUsageDescription is missing, does not mention Music Assistant, or still mentions Plex"; exit 1; }
# #0075: the Wi-Fi name needs Location access; both descriptions must say why.
for key in NSLocationUsageDescription NSLocationWhenInUseUsageDescription; do
  loc="$(get $key || true)"
  print -r -- "$key = ${loc:-<absent>}"
  [[ "$loc" == *Wi-Fi* ]] || { print -u2 "!! $key is missing or does not mention Wi-Fi"; exit 1; }
done
expect UTExportedTypeDeclarations.0.UTTypeIdentifier co.sstools.roadie.wsz
# #0047: the open panel filter relies on this conformance.
expect UTExportedTypeDeclarations.0.UTTypeConformsTo.0 public.zip-archive
expect UTExportedTypeDeclarations.1.UTTypeIdentifier co.sstools.roadie.media-id
expect UTExportedTypeDeclarations.1.UTTypeConformsTo.0 public.data
expect CFBundleDocumentTypes.0.LSItemContentTypes.0 co.sstools.roadie.wsz
print -r -- "Info.plist OK: $P"
