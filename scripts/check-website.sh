#!/bin/zsh
# check-website.sh — read-only lint of website/ before a deploy (#0163, docs/design/release.md §2.6,
# docs/website-hosting.md). Checks:
#   - appcast.xml is well-formed XML (xmllint).
#   - every href/src in the top-level *.html, every icon and start_url in *.webmanifest, and every url(...) in
#     css/*.css resolves to a file under website/. A downloads/Roadie-X.Y.Z.dmg link that isn't on disk (DMGs are
#     never committed) is allowed only with --expect-dmg X.Y.Z or when the vX.Y.Z GitHub release exists (gh).
#   - nothing external: no external src/script/stylesheet/url() except fonts.googleapis.com and fonts.gstatic.com;
#     plain <a href> links may go to github.com and the canonical https://roadie.sstools.co/ only.
#   - no *.dmg tracked by git (skipped when git or the repo isn't available, e.g. in the VM).
# Runs on the host and as the `website` step in scripts/run-tests-vm.sh. Exits 1 and lists every problem.
# Usage: scripts/check-website.sh [--expect-dmg X.Y.Z]
set -euo pipefail
cd "${0:A:h}/.."

expect_dmg=""
while (( $# )); do
  case $1 in
    --expect-dmg) expect_dmg=${2:?--expect-dmg needs a version}; shift 2 ;;
    *) print -u2 "usage: scripts/check-website.sh [--expect-dmg X.Y.Z]"; exit 2 ;;
  esac
done

[[ -d website ]] || { print -u2 "!! website/ is missing"; exit 1; }
bad=0

if ! xmllint --noout website/appcast.xml; then print -u2 "!! website/appcast.xml is not well-formed XML"; bad=$((bad + 1)); fi

# The reference walk is in Python (stdlib only) so HTML attributes are parsed, not grepped.
python3 -I - "$expect_dmg" <<'PY' || bad=$((bad + 1))
import json, os, re, subprocess, sys, shutil
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote

expect = sys.argv[1]
root = os.path.abspath("website")
FONT_HOSTS = {"fonts.googleapis.com", "fonts.gstatic.com"}
LINK_HOSTS = {"github.com", "roadie.sstools.co"}
problems = []
gh_cache = {}
skipped_release_checks = set()

def release_exists(version):
    if version not in gh_cache:
        ok = False
        if shutil.which("gh"):
            r = subprocess.run(["gh", "release", "view", f"v{version}", "--repo", "brennanMKE/Roadie"],
                               capture_output=True)
            ok = r.returncode == 0
        gh_cache[version] = ok
    return gh_cache[version]

def check(where, ref, kind):
    """kind: 'link' (<a href>, canonical, og:url), 'font' (stylesheet/url() allowed on font hosts), 'local'."""
    ref = ref.strip()
    if not ref or ref.startswith("#") or ref.startswith("mailto:"):
        return
    parts = urlsplit(ref)
    if parts.scheme or parts.netloc:
        host = parts.hostname or ""
        if parts.scheme != "https":
            problems.append(f"{where}: non-https external reference {ref}")
        elif kind == "link" and host in LINK_HOSTS:
            pass
        elif kind == "font" and host in FONT_HOSTS:
            pass
        else:
            problems.append(f"{where}: external reference not allowed here: {ref}")
        return
    path = unquote(parts.path)
    base = root if path.startswith("/") else os.path.dirname(where_abs[where])
    target = os.path.normpath(os.path.join(base, path.lstrip("/")))
    if not target.startswith(root):
        problems.append(f"{where}: {ref} points outside website/"); return
    if os.path.isdir(target):
        target = os.path.join(target, "index.html")
    if os.path.isfile(target):
        return
    m = re.fullmatch(r"downloads/Roadie-(\d[0-9A-Za-z.\-]*)\.dmg", os.path.relpath(target, root))
    if m:
        v = m.group(1)
        if v == expect or release_exists(v):
            return
        if not shutil.which("gh"):
            skipped_release_checks.add(v)  # e.g. the VM guest: no gh, so the release can't be checked here
            return
        problems.append(f"{where}: {ref} has no GitHub release v{v} (pass --expect-dmg {v} during a release)")
        return
    problems.append(f"{where}: {ref} does not resolve to a file under website/")

where_abs = {}

class Refs(HTMLParser):
    def __init__(self, name):
        super().__init__(); self.name = name
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "href" in a and a["href"] is not None:
            rel = (a.get("rel") or "").lower()
            if tag == "a" or (tag == "link" and rel == "canonical"):
                kind = "link"
            elif tag == "link" and rel == "stylesheet":
                kind = "font"
            else:
                kind = "local"
            check(self.name, a["href"], kind)
        if "src" in a and a["src"] is not None:
            check(self.name, a["src"], "local")
        if tag == "meta" and a.get("property") in ("og:url", "og:image") and a.get("content"):
            check(self.name, a["content"], "link" if a["property"] == "og:url" else "local")
        if "style" in a and a["style"]:
            for u in re.findall(r"url\(\s*['\"]?([^'\")]+)", a["style"]):
                check(self.name, u, "local")

for f in sorted(os.listdir(root)):
    p = os.path.join(root, f)
    if f.endswith(".html") and os.path.isfile(p):
        where_abs[f] = p
        text = open(p, encoding="utf-8").read()
        Refs(f).feed(text)
        for u in re.findall(r"url\(\s*['\"]?([^'\")]+)", "".join(re.findall(r"<style[^>]*>(.*?)</style>", text, re.S))):
            check(f, u, "local")
    elif f.endswith(".webmanifest") and os.path.isfile(p):
        where_abs[f] = p
        try:
            m = json.load(open(p, encoding="utf-8"))
        except ValueError as e:
            problems.append(f"{f}: invalid JSON: {e}"); continue
        for icon in m.get("icons", []):
            check(f, icon.get("src", ""), "local")
        if "start_url" in m:
            check(f, m["start_url"], "local")

css_dir = os.path.join(root, "css")
if os.path.isdir(css_dir):
    for f in sorted(os.listdir(css_dir)):
        if f.endswith(".css"):
            name = f"css/{f}"; where_abs[name] = os.path.join(css_dir, f)
            text = open(where_abs[name], encoding="utf-8").read()
            refs = re.findall(r"url\(\s*['\"]?([^'\")]+)", text)
            refs += re.findall(r"@import\s+['\"]([^'\"]+)['\"]", text)
            for u in refs:
                check(name, u, "font")

for v in sorted(skipped_release_checks):
    print(f"(gh not available; skipped the GitHub release check for v{v})")
for p in problems:
    print(f"!! {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

if command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dmgs=$(git ls-files -- '*.dmg' || true)
  if [[ -n $dmgs ]]; then print -u2 -r -- "!! DMGs tracked by git:"$'\n'"$dmgs"; bad=$((bad + 1)); fi
else
  print -r -- "(git not available; skipped the tracked-DMG check)"
fi

if (( bad )); then print -u2 -r -- "!! website check failed"; exit 1; fi
print -r -- "website OK: appcast is valid XML, every local reference resolves, no external hosts beyond Google Fonts and plain links"
