#!/bin/zsh
# preflight.sh — check that a Roadie release can start (M14 W9, docs/design/release.md).
#
# Usage: scripts/preflight.sh --release X.Y.Z [options]
#        scripts/preflight.sh --credentials-only [options]
#   --release X.Y.Z        repo, version, tool and credential gates for that version
#   --credentials-only     tool and credential gates only
#   --strict               WARN counts as FAIL
#   --build-number N       N must be greater than the newest sparkle:version in website/appcast.xml
#   --identity NAME        Developer ID Application identity (default: the first one in the keychain)
#   --notary-profile NAME  notarytool keychain profile (default: Roadie-notary)
#   --sparkle-bin DIR      directory with generate_keys (default: build/sparkle/bin)
#
# One line per gate (PASS/FAIL/WARN), then a summary. Exits 1 if any gate fails.
# Never prints a secret: only identity names, profile names, key match/no match.

set -euo pipefail
if [[ -o xtrace ]]; then
  print -u2 "preflight.sh: refusing to run with xtrace on (it could echo secrets)"
  exit 2
fi

SCRIPT=${0:A}
ROOT=${SCRIPT:h:h}
cd "$ROOT"

usage() { sed -n '2,15p' "$SCRIPT" | sed 's/^# \{0,1\}//'; }

mode="" version="" strict=0 build_number="" identity="" notary_profile="Roadie-notary"
sparkle_bin="$ROOT/build/sparkle/bin"
while (( $# )); do
  case $1 in
    --release) mode=release; version=${2:-}; shift ;;
    --credentials-only) mode=credentials ;;
    --strict) strict=1 ;;
    --build-number) build_number=${2:-}; shift ;;
    --identity) identity=${2:-}; shift ;;
    --notary-profile) notary_profile=${2:-}; shift ;;
    --sparkle-bin) sparkle_bin=${2:-}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "preflight.sh: unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done
[[ -n $mode ]] || { usage >&2; exit 2; }
if [[ $mode == release && ! $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "preflight.sh: --release needs X.Y.Z"; exit 2
fi
if [[ -n $build_number && ! $build_number =~ '^[0-9]{8}\.[0-9]{1,4}$' ]]; then
  print -u2 "preflight.sh: --build-number must be YYYYMMDD.HHMM"; exit 2
fi

fails=0 warns=0 passes=0
pass() { print "PASS  $1"; (( ++passes )); }
fail() { print "FAIL  $1"; (( ++fails )); }
warn() {
  if (( strict )); then print "FAIL  $1 (strict)"; (( ++fails ))
  else print "WARN  $1"; (( ++warns )); fi
}
have() { command -v "$1" >/dev/null 2>&1; }

# semver_gt A B: true when A > B
semver_gt() {
  local -a a b; a=(${(s:.:)1}) b=(${(s:.:)2})
  local i
  for i in 1 2 3; do
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
  done
  return 1
}
# build_gt A B for YYYYMMDD.HHMM: compare (date, time) as integers
build_gt() {
  local ad=${1%%.*} at=${1#*.} bd=${2%%.*} bt=${2#*.}
  [[ $at == $1 ]] && at=0; [[ $bt == $2 ]] && bt=0
  (( 10#$ad > 10#$bd )) && return 0
  (( 10#$ad < 10#$bd )) && return 1
  (( 10#$at > 10#$bt ))
}

appcast="$ROOT/website/appcast.xml"
appcast_values() { # attribute or element name -> values, one per line
  [[ -s $appcast ]] || return 0
  grep -oE "sparkle:$1(=\"|>)[^\"<]+" "$appcast" | sed -E "s/^sparkle:$1(=\"|>)//" || true
}

# --- tools
for t in xcrun hdiutil codesign stapler spctl xmllint gh python3 tart; do
  case $t in
    stapler) if have xcrun && xcrun --find stapler >/dev/null 2>&1; then pass "tool: stapler"; else fail "tool: stapler missing"; fi ;;
    *) if have $t; then pass "tool: $t"; else fail "tool: $t missing"; fi ;;
  esac
done

# --- repo gates
if [[ $mode == release ]]; then
  if [[ -z $(git status --porcelain) ]]; then pass "repo: tree clean"; else fail "repo: uncommitted changes"; fi
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [[ $branch == main ]]; then pass "repo: on main"; else fail "repo: on '$branch', not main"; fi

  mv_line=$(awk '
    /^settings:/ {s=1; next}
    s && /^[^ ]/ {s=0}
    s && /^  base:/ {b=1; next}
    b && /^  [^ ]/ {b=0}
    b && /MARKETING_VERSION:/ {print; exit}' project.yml)
  [[ -n $mv_line ]] || mv_line=$(grep -m1 'MARKETING_VERSION:' project.yml || true)
  marketing=$(print -r -- "$mv_line" | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/')
  if [[ $marketing == $version ]]; then pass "version: MARKETING_VERSION is $version"
  else fail "version: MARKETING_VERSION is '${marketing:-missing}', not $version"; fi

  newest=""
  for v in $(appcast_values shortVersionString); do
    if [[ -z $newest ]] || semver_gt $v $newest; then newest=$v; fi
  done
  if [[ -z $newest ]]; then pass "version: no earlier release in the appcast"
  elif semver_gt $version $newest; then pass "version: $version > appcast $newest"
  else fail "version: $version is not greater than appcast $newest"; fi

  if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then fail "tag: v$version exists locally"
  else pass "tag: v$version absent locally"; fi
  if remote_tags=$(git ls-remote --tags origin "refs/tags/v$version" 2>/dev/null); then
    if [[ -n $remote_tags ]]; then fail "tag: v$version exists on origin"; else pass "tag: v$version absent on origin"; fi
  else
    fail "tag: could not query origin"
  fi

  if [[ -f CHANGELOG.md ]] && grep -qF "## [$version]" CHANGELOG.md; then pass "changelog: ## [$version] present"
  else fail "changelog: no '## [$version]' in CHANGELOG.md"; fi
fi

if [[ -n $build_number ]]; then
  highest=""
  for b in $(appcast_values version); do
    if [[ -z $highest ]] || build_gt $b $highest; then highest=$b; fi
  done
  if [[ -z $highest ]]; then pass "build: $build_number (no earlier build in the appcast)"
  elif build_gt $build_number $highest; then pass "build: $build_number > appcast $highest"
  else fail "build: $build_number is not greater than appcast $highest"; fi
fi

# --- credentials
if have security; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Developer ID Application: [^"]+"' | tr -d '"' || true)
  if [[ -z $identity ]]; then local_ids=(${(f)identities}); identity=${local_ids[1]:-}; fi
  if [[ -n $identity ]] && print -r -- "$identities" | grep -qxF "$identity"; then
    pass "identity: $identity"
    pem=$(security find-certificate -c "$identity" -p 2>/dev/null || true)
    enddate=$(print -r -- "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
    if [[ -z $enddate ]]; then warn "identity: could not read certificate expiry"
    else
      end=$(date -j -f '%b %e %H:%M:%S %Y %Z' "$enddate" +%s 2>/dev/null || print 0)
      days=$(( (end - $(date +%s)) / 86400 ))
      if (( end == 0 )); then warn "identity: could not parse expiry '$enddate'"
      elif (( days < 0 )); then fail "identity: certificate expired $enddate"
      elif (( days < 30 )); then warn "identity: certificate expires in $days days"
      else pass "identity: certificate valid for $days days"; fi
    fi
  else
    fail "identity: no Developer ID Application identity${identity:+ named '$identity'}"
  fi
else
  fail "identity: security tool missing"
fi

if have xcrun && xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
  pass "notary: profile $notary_profile usable"
else
  fail "notary: profile $notary_profile not usable"
fi

# The Release config's key; the Debug config above it is deliberately empty.
project_key=$(awk '/^[[:space:]]*Release:[[:space:]]*$/ { rel = 1; next }
  rel && /ROADIE_PUBLIC_ED_KEY:/ { sub(/.*ROADIE_PUBLIC_ED_KEY:[[:space:]]*"?/, ""); sub(/"?[[:space:]]*$/, ""); print; exit }' \
  project.yml 2>/dev/null || true)
if [[ -z $project_key ]]; then
  fail "sparkle: ROADIE_PUBLIC_ED_KEY empty in project.yml (W15 not done)"
elif [[ ! -x $sparkle_bin/generate_keys ]]; then
  fail "sparkle: $sparkle_bin/generate_keys missing"
else
  keychain_key=$("$sparkle_bin/generate_keys" --account Roadie -p 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true)
  if [[ -n $keychain_key && $keychain_key == $project_key ]]; then pass "sparkle: keychain key matches project.yml"
  else fail "sparkle: keychain key does not match project.yml (no match)"; fi
  unset keychain_key
fi

if have gh && gh auth status >/dev/null 2>&1; then pass "gh: authenticated"
else fail "gh: not authenticated"; fi

print -r -- "---"
print "preflight: $passes passed, $warns warnings, $fails failed"
(( fails == 0 ))
