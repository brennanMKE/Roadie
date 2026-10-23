#!/bin/zsh
# release.sh — build, sign, package and (with --publish) ship Roadie X.Y.Z (#0162, M14 W11,
# docs/design/release.md §2.5, docs/releasing.md).
#
# Usage: scripts/release.sh X.Y.Z [--publish] [--notary-profile NAME] [--identity NAME] [--repo OWNER/NAME]
#                                 [--skip-build ZIP]
#   (default)             rehearsal: every local step except notarization; writes only under build/release/X.Y.Z/
#                         (steps 9-11 edit a temporary copy of website/); no tag, commit, push or gh.
#                         Preflight and credential failures are reported but don't stop it; without the Sparkle
#                         key the appcast item uses a stub signature.
#   --publish             the real release (user only): strict preflight, notarize and staple, edit website/,
#                         tag the built commit, commit website/, push after a y/N prompt, gh release create.
#   --notary-profile NAME notarytool keychain profile (default Roadie-notary)
#   --identity NAME       Developer ID Application identity (default: the first in the keychain)
#   --repo OWNER/NAME     GitHub repo for the release (default brennanMKE/Roadie)
#   --skip-build ZIP      rehearsal only: reuse an existing VM Roadie.app.zip instead of step 1
#
# Secrets: never sources .env; no secret on any command line (notary profile, login-keychain Sparkle key,
# gh's own auth); prints only names, ids, hashes and paths.

set -euo pipefail
if [[ -o xtrace || -n ${XTRACE:-} ]]; then print -u2 "release.sh: refusing to run with xtrace on"; exit 2; fi
unsetopt xtrace

ROOT=${0:A:h:h}
cd "$ROOT"

VERSION="" PUBLISH=0 PROFILE="Roadie-notary" IDENTITY="" REPO_SLUG="brennanMKE/Roadie" SKIP_ZIP=""
usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; }
die() { print -u2 "release.sh: $*"; exit 1 }
while (( $# )); do
  case $1 in
    --publish) PUBLISH=1; shift ;;
    --notary-profile) PROFILE=${2:?}; shift 2 ;;
    --identity) IDENTITY=${2:?}; shift 2 ;;
    --repo) REPO_SLUG=${2:?}; shift 2 ;;
    --skip-build) SKIP_ZIP=${2:?}; SKIP_ZIP=${SKIP_ZIP:A}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z $VERSION ]] || die "one version only"; VERSION=$1; shift ;;
  esac
done
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { usage >&2; exit 2 }
[[ $REPO_SLUG =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || die "--repo must be OWNER/NAME"
(( PUBLISH && ${#SKIP_ZIP} )) && die "--skip-build is for rehearsals only"
[[ -z $SKIP_ZIP || -f $SKIP_ZIP ]] || die "no zip at $SKIP_ZIP"

OUT="$ROOT/build/release/$VERSION"
DMG_NAME="Roadie-$VERSION.dmg"
TAG="v$VERSION"
MODE=$([[ $PUBLISH == 1 ]] && print publish || print rehearsal)
typeset -a ISSUES
note() { print "==> $*" }
step() { print; print "=== $* ===" }
issue() { ISSUES+=("$1"); print "!!  $1 (rehearsal: continuing)" }

mkdir -p "$OUT"
TMPW=$(mktemp -d "${TMPDIR:-/tmp}/roadie-release.XXXXXX")
trap 'rm -rf "$TMPW"' EXIT
note "Roadie $VERSION, $MODE; output $OUT"

BUILD=$(date -u +%Y%m%d.%H%M)
BUILT_COMMIT=$(git rev-parse HEAD)

# Step 0: preflight.
step "0 Preflight"
pf=(--release "$VERSION" --notary-profile "$PROFILE")
[[ -n $IDENTITY ]] && pf+=(--identity "$IDENTITY")
if (( PUBLISH )); then
  scripts/preflight.sh "${pf[@]}" --build-number "$BUILD" --strict || die "preflight failed"
else
  [[ -n $SKIP_ZIP ]] || pf+=(--build-number "$BUILD")
  scripts/preflight.sh "${pf[@]}" || issue "preflight reported failures"
fi

# Step 1: build and test in the VM.
step "1 Build and test (VM)"
if [[ -n $SKIP_ZIP ]]; then
  ZIP=$SKIP_ZIP
  BUILD=$(unzip -p "$ZIP" Roadie.app/Contents/Info.plist | plutil -extract CFBundleVersion raw -) \
    || die "can't read CFBundleVersion from $ZIP"
  note "--skip-build: reusing $ZIP (build $BUILD)"
else
  vlog="$OUT/verify.log"
  scripts/verify.sh --head --full --launch --dmg --build-number "$BUILD" 2>&1 | tee "$vlog" \
    || die "verify.sh failed; log in $vlog"
  ZIP=$(sed -nE 's/^==> RELEASE  ([^ ]+) build .*/\1/p' "$vlog" | tail -1)
  [[ -f $ZIP ]] || die "no RELEASE line with a zip in $vlog"
  note "zip $ZIP (build $BUILD), commit $BUILT_COMMIT"
fi

# Steps 2-8: unpack, version gate, sign, DMG, [notarize, staple], final name, sha256.
step "2-8 Sign and package"
md=("$ZIP" --release "$VERSION" --out "$OUT")
[[ -n $IDENTITY ]] && md+=(--identity "$IDENTITY")
(( PUBLISH )) && md+=(--notary-profile "$PROFILE")
scripts/make-dmg.sh "${md[@]}" || die "make-dmg.sh failed"
DMG="$OUT/$DMG_NAME"
[[ -f $DMG && -f $DMG.sha256 ]] || die "make-dmg.sh didn't produce $DMG and its .sha256"

step "6 Verify the DMG"
if (( PUBLISH )); then
  xcrun stapler validate "$DMG" >/dev/null || die "stapler validate failed"
  spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || die "spctl rejected $DMG"
  scripts/verify-dmg.sh "$DMG" || die "verify-dmg.sh failed"
else
  scripts/verify-dmg.sh "$DMG" --allow-unnotarized || die "verify-dmg.sh failed"
fi
SHA=$(cut -d' ' -f1 "$DMG.sha256")
SIZE=$(stat -f %z "$DMG")
note "$DMG_NAME  $SIZE bytes  sha256 $SHA"

# Steps 9-11 edit website/ (publish) or a temporary copy of the repo's website/ and checker (rehearsal).
if (( PUBLISH )); then
  SITE_ROOT=$ROOT
else
  SITE_ROOT="$TMPW/site"
  mkdir -p "$SITE_ROOT/scripts"
  cp -R "$ROOT/website" "$SITE_ROOT/website"
  cp "$ROOT/scripts/check-website.sh" "$SITE_ROOT/scripts/"
  note "rehearsal: editing a copy of website/ in $SITE_ROOT"
fi
SITE="$SITE_ROOT/website"

# Step 10 runs before 9 so appcast-item.sh picks up the rendered <description>.
step "10 Changelog"
if ! python3 -I scripts/render-changelog.py "$VERSION" --website "$SITE" --out "$ROOT/build/release"; then
  (( PUBLISH )) && die "render-changelog.py failed"
  issue "CHANGELOG.md has no usable ## [$VERSION] section; no release notes"
fi

step "9 Appcast item"
ac=("$DMG" --version "$VERSION" --appcast "$SITE/appcast.xml")
if (( PUBLISH )); then
  scripts/appcast-item.sh "${ac[@]}" || die "appcast-item.sh failed"
  awk '/<item>/{f=1} f{print} /<\/item>/{exit}' "$SITE/appcast.xml" > "$OUT/appcast-item.xml"
else
  if scripts/appcast-item.sh "${ac[@]}" --dry-run > "$OUT/appcast-item.xml" 2>"$TMPW/ac.err"; then
    note "signed with the Sparkle key (dry run)"
  else
    sed 's/^/    /' "$TMPW/ac.err" >&2
    issue "sign_update unavailable or failed; appcast item uses a stub signature"
    scripts/appcast-item.sh "${ac[@]}" --dry-run --signature-stub > "$OUT/appcast-item.xml" \
      || die "appcast-item.sh failed"
  fi
  ITEM_FILE="$OUT/appcast-item.xml" python3 -I - "$SITE/appcast.xml" <<'PY' || die "couldn't insert the item into the copy"
import os, sys
path, item = sys.argv[1], open(os.environ["ITEM_FILE"], encoding="utf-8").read().rstrip("\n")
text = open(path, encoding="utf-8").read()
i = text.find("<item>")
i = text.find("</channel>") if i < 0 else i
i = text.rfind("\n", 0, i) + 1
open(path, "w", encoding="utf-8").write(text[:i] + item + "\n" + text[i:])
PY
  xmllint --noout "$SITE/appcast.xml" || die "the rehearsal appcast is not valid XML"
fi
note "item in $OUT/appcast-item.xml"

step "11 Download link"
VERSION="$VERSION" REPO_SLUG="$REPO_SLUG" python3 -I - "$SITE/index.html" <<'PY' || die "couldn't rewrite the download block"
import os, sys
path, v, repo = sys.argv[1], os.environ["VERSION"], os.environ["REPO_SLUG"]
B, E = "<!-- download:begin -->", "<!-- download:end -->"
text = open(path, encoding="utf-8").read()
if text.count(B) != 1 or text.count(E) != 1 or text.index(B) > text.index(E):
    sys.exit("release.sh: %s needs exactly one download:begin/end pair" % path)
block = (B + "\n"
  '<div class="download" id="download">\n'
  '<a class="download-button" href="downloads/Roadie-%s.dmg"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12"></path><path d="M7 10l5 5 5-5"></path><path d="M5 21h14"></path></svg>Download Roadie %s</a>\n'
  '<div class="download-meta">Requires macOS 14 Sonoma or later<br><a href="https://github.com/%s/releases/tag/v%s">Checksum and release notes on GitHub</a></div>\n'
  '</div>\n' % (v, v, repo, v) + E)
open(path, "w", encoding="utf-8").write(text[:text.index(B)] + block + text[text.index(E) + len(E):])
PY
"$SITE_ROOT/scripts/check-website.sh" --expect-dmg "$VERSION" || die "check-website.sh failed"
(( PUBLISH )) || cp "$SITE/index.html" "$OUT/rehearsal-index.html"

if (( ! PUBLISH )); then
  step "Rehearsal done"
  note "nothing was notarized, tagged, committed, pushed or uploaded; website/ and git untouched"
  ls -1 "$OUT" | sed 's/^/    /'
  if (( ${#ISSUES} )); then
    print "Fix before --publish:"
    for i in "${ISSUES[@]}"; do print "  - $i"; done
  fi
  exit 0
fi

# Step 12: tag the built commit, commit website/.
step "12 Tag and commit"
git tag -a "$TAG" -m "Roadie $VERSION" "$BUILT_COMMIT"
git add -- website
git commit -q -m "Release $VERSION: appcast, changelog, download link"
note "tag $TAG on $BUILT_COMMIT; website commit $(git rev-parse --short HEAD)"

# Step 13: push after a prompt.
step "13 Push"
read -r "?Push main and $TAG to origin? [y/N] " answer
[[ $answer == [yY] ]] || die "not pushed. To undo: git tag -d $TAG && git reset --hard HEAD~1"
git push origin main "$TAG"

# Step 14: GitHub release, then re-download and compare.
step "14 GitHub release"
NOTES="$OUT/release-notes.md"
[[ -f $NOTES ]] || die "no $NOTES"
gh release create "$TAG" "$DMG" "$DMG.sha256" --repo "$REPO_SLUG" --verify-tag \
  --title "Roadie $VERSION" --notes-file "$NOTES"
DL="$TMPW/download"; mkdir "$DL"
gh release download "$TAG" --repo "$REPO_SLUG" --pattern "$DMG_NAME" --dir "$DL"
remote=$(shasum -a 256 "$DL/$DMG_NAME" | cut -d' ' -f1)
[[ $remote == $SHA ]] || die "downloaded sha256 $remote != local $SHA"
note "GitHub asset sha256 matches: $SHA"

# Step 15: hand-off.
step "15 Hand-off"
cat <<EOF
- [x] The $TAG GitHub release is published with $DMG_NAME and $DMG_NAME.sha256.
- [x] website/appcast.xml has the new item first, generated from that DMG.
- [x] website/changelog.html has <article id="v${VERSION//./-}">.
- [x] The download button in index.html points at the new DMG.
- [x] xmllint --noout website/appcast.xml passes.
- [ ] Previewed locally with: cd website && python3 -m http.server 8000
- [x] Committed and pushed.
EOF
print "Ask for the site to be deployed."
