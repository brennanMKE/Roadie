#!/usr/bin/env python3
"""Render one CHANGELOG.md release section (#0161, docs/design/release.md §2.5 step 10).

usage: scripts/render-changelog.py X.Y.Z [--date YYYY-MM-DD] [--changelog CHANGELOG.md]
                                   [--website website] [--out build/release]

Reads `## [X.Y.Z] - YYYY-MM-DD` from CHANGELOG.md and writes:
  1. <article id="vX-Y-Z"> prepended between <!-- releases:begin --> and <!-- releases:end --> in
     <website>/changelog.html; the fragment is always also written to <out>/X.Y.Z/changelog-article.html,
     and when the page doesn't exist that's the only copy;
  2. <out>/X.Y.Z/appcast-description.html, the HTML for the appcast item's <description> CDATA
     (scripts/appcast-item.sh picks it up);
  3. <out>/X.Y.Z/release-notes.md for the GitHub release.
Stdlib only. Exits non-zero when the version has no section.
"""
import argparse
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BEGIN, END = "<!-- releases:begin -->", "<!-- releases:end -->"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
INLINE_RE = re.compile(r"`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)")


def anchor(version):
    return "v" + version.replace(".", "-")


def parse_section(text, version):
    """Returns (date or None, [(heading, [bullet, ...]), ...]), or None when the version is missing."""
    head = re.compile(r"^## \[" + re.escape(version) + r"\](?:\s+-\s+(\S+))?\s*$")
    date, groups, inside = None, [], False
    for line in text.splitlines():
        if line.startswith("## "):
            if inside:
                break
            m = head.match(line)
            if m:
                inside, date = True, m.group(1)
            continue
        if not inside:
            continue
        if line.startswith("### "):
            groups.append((line[4:].strip(), []))
        elif line.startswith("- "):
            if not groups:
                groups.append(("Changes", []))
            groups[-1][1].append(line[2:].strip())
        elif line.startswith("  ") and line.strip() and groups and groups[-1][1]:
            groups[-1][1][-1] += " " + line.strip()  # wrapped bullet
    return (date, groups) if inside else None


def inline_html(text):
    out, pos = [], 0
    for m in INLINE_RE.finditer(text):
        out.append(html.escape(text[pos:m.start()]))
        if m.group(1) is not None:
            out.append("<code>" + html.escape(m.group(1)) + "</code>")
        else:
            out.append('<a href="%s">%s</a>' % (html.escape(m.group(3)), html.escape(m.group(2))))
        pos = m.end()
    out.append(html.escape(text[pos:]))
    return "".join(out)


def groups_html(groups, level):
    parts = []
    for heading, bullets in groups:
        parts.append("<h%d>%s</h%d>" % (level, html.escape(heading), level))
        parts.append("<ul>\n" + "".join("  <li>%s</li>\n" % inline_html(b) for b in bullets) + "</ul>")
    return "\n".join(parts)


def article_html(version, date, groups):
    lines = ['<article id="%s">' % anchor(version), "<h2>Roadie %s</h2>" % html.escape(version)]
    if date:
        lines.append('<p><time datetime="%s">%s</time></p>' % (html.escape(date), html.escape(date)))
    lines += [groups_html(groups, 3), "</article>"]
    return "\n".join(lines) + "\n"


def notes_md(groups):
    return "\n".join("### %s\n\n%s\n" % (h, "\n".join("- " + b for b in bs)) for h, bs in groups)


def insert_article(page, article, version):
    text = page.read_text(encoding="utf-8")
    if BEGIN not in text or END not in text:
        raise SystemExit("error: %s lacks the %s / %s markers" % (page, BEGIN, END))
    if 'id="%s"' % anchor(version) in text:
        raise SystemExit("error: %s already has an article for %s" % (page, version))
    i = text.index(BEGIN) + len(BEGIN)
    page.write_text(text[:i] + "\n" + article.rstrip("\n") + text[i:], encoding="utf-8")


def main(argv=None):
    p = argparse.ArgumentParser(description="Render one CHANGELOG.md release section.")
    p.add_argument("version")
    p.add_argument("--date", help="release date; overrides the date in the heading")
    p.add_argument("--changelog", type=Path, default=ROOT / "CHANGELOG.md")
    p.add_argument("--website", type=Path, default=ROOT / "website")
    p.add_argument("--out", type=Path, default=ROOT / "build" / "release")
    a = p.parse_args(argv)
    if not VERSION_RE.match(a.version):
        print("error: version must be X.Y.Z", file=sys.stderr)
        return 2
    parsed = parse_section(a.changelog.read_text(encoding="utf-8"), a.version)
    if parsed is None:
        print("error: %s has no ## [%s] section" % (a.changelog, a.version), file=sys.stderr)
        return 1
    date, groups = parsed
    date = a.date or date
    if not any(bullets for _, bullets in groups):
        print("error: ## [%s] has no bullets" % a.version, file=sys.stderr)
        return 1
    out = a.out / a.version
    out.mkdir(parents=True, exist_ok=True)
    article = article_html(a.version, date, groups)
    (out / "changelog-article.html").write_text(article, encoding="utf-8")
    (out / "appcast-description.html").write_text(groups_html(groups, 3) + "\n", encoding="utf-8")
    (out / "release-notes.md").write_text(notes_md(groups), encoding="utf-8")
    page = a.website / "changelog.html"
    if page.exists():
        insert_article(page, article, a.version)
        print("updated %s (#%s)" % (page, anchor(a.version)))
    else:
        print("note: %s doesn't exist; the article is only in %s" % (page, out / "changelog-article.html"))
    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
