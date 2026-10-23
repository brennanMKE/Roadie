#!/bin/zsh
# deploy-website.sh — publish website/ to https://roadie.sstools.co/ (docs/website-hosting.md), the same way the
# other sstools.co sites are deployed: rsync over SSH to the EC2 host's Apache vhost.
#
#   1. Checks website/ (scripts/check-website.sh) and that the tree is committed.
#   2. --setup only: creates the vhost on the host (HTTP->HTTPS redirect, the sstools.co wildcard certificate),
#      runs `apachectl configtest` and reloads Apache gracefully. Run once.
#   3. rsyncs website/ to the document root with --delete, leaving downloads/ alone (old DMGs stay published).
#   4. For every enclosure in appcast.xml whose DMG the host lacks: downloads it from the matching GitHub release,
#      checks it against the release's .sha256 and the enclosure length, and uploads it with its .sha256.
#   5. Verifies over HTTPS: every page, the appcast, each DMG's length, and the http->https redirect.
#
# Usage: scripts/deploy-website.sh [--setup] [--dry-run]
# Environment (all optional):
#   ROADIE_DEPLOY_HOST  SSH host or alias (default: ec2)
#   ROADIE_DEPLOY_PATH  document root (default: /var/www/vhosts/roadie.sstools.co)
set -euo pipefail
cd "${0:A:h}/.."

HOST=${ROADIE_DEPLOY_HOST:-ec2}
DOCROOT=${ROADIE_DEPLOY_PATH:-/var/www/vhosts/roadie.sstools.co}
SITE=roadie.sstools.co
REPO_SLUG=brennanMKE/Roadie
SETUP=0; DRY=0
while (( $# )); do
  case $1 in
    --setup) SETUP=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) print -u2 "usage: scripts/deploy-website.sh [--setup] [--dry-run]"; exit 2 ;;
  esac
  shift
done

note() { print -r -- "==> $*"; }
fail() { print -u2 -r -- "!! $*"; exit 1; }
# ClearAllForwardings: the host alias may forward ports for other work; a deploy needs none.
SSH_OPTS=(-o ClearAllForwardings=yes -o ConnectTimeout=15 -o BatchMode=yes)
remote() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

for t in rsync ssh curl gh shasum xmllint; do command -v $t >/dev/null || fail "$t not found"; done

# --- 1. Local checks ----------------------------------------------------------
scripts/check-website.sh
[[ -z $(git status --porcelain -- website) ]] || fail "website/ has uncommitted changes; commit them first"
remote true || fail "cannot reach $HOST over SSH"

# --- 2. One-time vhost setup --------------------------------------------------
if (( SETUP )); then
  note "Setting up the $SITE vhost on $HOST"
  conf=/etc/httpd/conf.d/001-$SITE.conf
  ssl=/etc/httpd/conf.d/001-$SITE-le-ssl.conf
  if remote "test -e $conf -o -e $ssl"; then
    note "vhost files already exist; leaving them unchanged"
  elif (( DRY )); then
    note "(dry run) would write $conf and $ssl and reload Apache"
  else
    remote "sudo -n true" || fail "passwordless sudo is needed on $HOST for --setup"
    remote "sudo mkdir -p $DOCROOT/downloads && sudo chown -R \$(id -un):\$(id -gn) $DOCROOT"
    remote "sudo tee $conf >/dev/null" <<EOF
<VirtualHost *:80>
    ServerName $SITE
    DocumentRoot "$DOCROOT"

    <Directory "$DOCROOT">
        AllowOverride None
        Options FollowSymLinks
        Require all granted
    </Directory>

RewriteEngine on
RewriteCond %{SERVER_NAME} =$SITE
RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>
EOF
    remote "sudo tee $ssl >/dev/null" <<EOF
<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName $SITE
    DocumentRoot "$DOCROOT"

    <Directory "$DOCROOT">
        AllowOverride None
        Options FollowSymLinks
        Require all granted
    </Directory>

    AddType application/manifest+json .webmanifest
    AddType image/webp .webp
    AddType application/x-apple-diskimage .dmg
    <IfModule mod_headers.c>
    <Files "appcast.xml">
        Header set Cache-Control "no-cache"
    </Files>
    </IfModule>

    ErrorLog  "logs/roadie_error_log"
    CustomLog "logs/roadie_access_log" combined

    Include /etc/letsencrypt/options-ssl-apache.conf
    SSLCertificateFile    /etc/letsencrypt/live/sstools.co-wildcard/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/sstools.co-wildcard/privkey.pem
</VirtualHost>
</IfModule>
EOF
    if ! remote "sudo apachectl configtest" 2>&1; then
      remote "sudo rm -f $conf $ssl"
      fail "apachectl configtest failed; removed the new vhost files, Apache was not reloaded"
    fi
    remote "sudo systemctl reload httpd"
    note "vhost created and Apache reloaded"
  fi
fi

remote "test -d $DOCROOT" || fail "$DOCROOT does not exist on $HOST; run with --setup once"

# --- 3. Upload the site -------------------------------------------------------
note "Uploading website/ to $HOST:$DOCROOT"
rsync_flags=(-rlptvz --delete --exclude .DS_Store --exclude .gitkeep --exclude 'downloads/' --exclude README.md)
(( DRY )) && rsync_flags+=(--dry-run)
rsync "${rsync_flags[@]}" -e "ssh ${SSH_OPTS[*]}" website/ "$HOST:$DOCROOT/"
remote "mkdir -p $DOCROOT/downloads"

# --- 4. DMGs from GitHub releases ---------------------------------------------
# One "<url> <length> <version>" line per appcast enclosure.
enclosures=$(python3 -I - website/appcast.xml <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    enc = item.find("enclosure")
    v = item.findtext("sparkle:shortVersionString", namespaces=ns) or enc.get("{%s}shortVersionString" % ns["sparkle"])
    print(enc.get("url"), enc.get("length"), v)
PY
)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dmg_names=()
while read -r url length version; do
  [[ -n $url ]] || continue
  name=${url:t}; dmg_names+=$name
  [[ $url == https://$SITE/downloads/$name ]] || fail "appcast enclosure $url is not under https://$SITE/downloads/"
  if remote "test -f $DOCROOT/downloads/$name" && [[ $(remote "stat -c %s $DOCROOT/downloads/$name") == $length ]]; then
    note "$name already on the host"
    continue
  fi
  note "Fetching $name from GitHub release v$version"
  gh release download "v$version" --repo $REPO_SLUG --pattern "$name" --pattern "$name.sha256" --dir "$tmp" --clobber
  ( cd "$tmp" && shasum -a 256 -c "$name.sha256" ) || fail "$name does not match its .sha256"
  [[ $(stat -f %z "$tmp/$name") == $length ]] || fail "$name is not the $length bytes the appcast says"
  if (( DRY )); then note "(dry run) would upload $name"; continue; fi
  rsync -tv -e "ssh ${SSH_OPTS[*]}" "$tmp/$name" "$tmp/$name.sha256" "$HOST:$DOCROOT/downloads/"
done <<< "$enclosures"

(( DRY )) && { note "Dry run done; nothing changed on $HOST"; exit 0; }

# --- 5. Verify over HTTPS -----------------------------------------------------
note "Verifying https://$SITE/"
bad=0
check_url() {  # url expected-status
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$1" || true)
  if [[ $code == $2 ]]; then print "PASS  $code $1"; else print "FAIL  $code $1 (expected $2)"; bad=$((bad + 1)); fi
}
for f in website/*.html website/*.xml website/*.webmanifest website/favicon.* website/css/*.css website/js/*.js \
         website/assets/*(.N) website/assets/screens/*(.N); do
  rel=${f#website/}; [[ $rel == assets/screens/manifest.json ]] && continue
  check_url "https://$SITE/$rel" 200
done
check_url "https://$SITE/" 200
check_url "http://$SITE/" 301
for name in $dmg_names; do
  len=$(curl -sI --max-time 30 "https://$SITE/downloads/$name" | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r')
  want=$(print -r -- "$enclosures" | awk -v n="$name" '$1 ~ "/" n "$" {print $2}')
  if [[ $len == $want ]]; then print "PASS  downloads/$name is $len bytes"
  else print "FAIL  downloads/$name is '${len:-missing}' bytes, appcast says $want"; bad=$((bad + 1)); fi
done
curl -s --max-time 30 "https://$SITE/appcast.xml" | xmllint --noout - || { print "FAIL  live appcast.xml is not valid XML"; bad=$((bad + 1)); }

(( bad == 0 )) || fail "$bad check(s) failed on https://$SITE/"
note "Deployed: https://$SITE/"
