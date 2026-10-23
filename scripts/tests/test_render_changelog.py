"""Tests for scripts/render-changelog.py (#0161). Stdlib only: python3 -m unittest discover -s scripts/tests -p 'test_render_changelog.py'"""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "render-changelog.py"
spec = importlib.util.spec_from_file_location("render_changelog", SCRIPT)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)

CHANGELOG = """# Changelog

## [Unreleased]

### Added

- Not released yet.

## [1.2.3] - 2026-11-01

### Added

- A [link](https://example.com/a?b=1&c=2) and `code <x>`.
- Escapes <b>tags</b> & ampersands.

### Fixed

- A wrapped bullet that
  continues here.

## [1.2.2] - 2026-10-01

### Changed

- Older entry.
"""

PAGE = """<html><body>
<!-- releases:begin -->
<article id="v1-2-2"><h2>Roadie 1.2.2</h2></article>
<!-- releases:end -->
</body></html>
"""


class RenderChangelogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.changelog = self.tmp / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG)
        self.web = self.tmp / "website"
        self.web.mkdir()
        self.out = self.tmp / "out"

    def run_script(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args, "--changelog", str(self.changelog),
                               "--website", str(self.web), "--out", str(self.out)],
                              capture_output=True, text=True)

    def test_parse_headings_and_bullets(self):
        date, groups = rc.parse_section(CHANGELOG, "1.2.3")
        self.assertEqual(date, "2026-11-01")
        self.assertEqual([h for h, _ in groups], ["Added", "Fixed"])
        self.assertEqual(len(groups[0][1]), 2)
        self.assertEqual(groups[1][1], ["A wrapped bullet that continues here."])

    def test_section_stops_at_next_release(self):
        _, groups = rc.parse_section(CHANGELOG, "1.2.3")
        self.assertNotIn("Older entry.", str(groups))

    def test_links_code_and_escaping(self):
        s = rc.inline_html("A [link](https://example.com/a?b=1&c=2) and `code <x>`, <b> & more")
        self.assertIn('<a href="https://example.com/a?b=1&amp;c=2">link</a>', s)
        self.assertIn("<code>code &lt;x&gt;</code>", s)
        self.assertIn("&lt;b&gt; &amp; more", s)

    def test_anchor(self):
        self.assertEqual(rc.anchor("1.2.3"), "v1-2-3")

    def test_outputs_and_page_insertion(self):
        (self.web / "changelog.html").write_text(PAGE)
        r = self.run_script("1.2.3", "--date", "2026-11-02")
        self.assertEqual(r.returncode, 0, r.stderr)
        page = (self.web / "changelog.html").read_text()
        self.assertLess(page.index('id="v1-2-3"'), page.index('id="v1-2-2"'))
        self.assertGreater(page.index('id="v1-2-3"'), page.index("<!-- releases:begin -->"))
        self.assertIn('<time datetime="2026-11-02">', page)
        self.assertIn("<h3>Fixed</h3>", page)
        self.assertIn("&lt;b&gt;tags&lt;/b&gt; &amp; ampersands", page)
        desc = (self.out / "1.2.3" / "appcast-description.html").read_text()
        self.assertIn("<li>", desc)
        self.assertNotIn("]]>", desc)
        notes = (self.out / "1.2.3" / "release-notes.md").read_text()
        self.assertIn("### Added", notes)
        self.assertIn("- A [link](https://example.com/a?b=1&c=2)", notes)
        # A second run refuses to add the same article twice.
        self.assertNotEqual(self.run_script("1.2.3").returncode, 0)

    def test_without_page_writes_fragment_only(self):
        r = self.run_script("1.2.3")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('<article id="v1-2-3">', (self.out / "1.2.3" / "changelog-article.html").read_text())
        self.assertFalse((self.web / "changelog.html").exists())

    def test_missing_version_fails(self):
        r = self.run_script("9.9.9")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("9.9.9", r.stderr)

    def test_bad_version_fails(self):
        self.assertNotEqual(self.run_script("1.2").returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
