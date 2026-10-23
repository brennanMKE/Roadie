"""Stub-based tests for scripts/preflight.sh (#0160) and a fixture-DMG test for scripts/appcast-item.sh (#0161).

Runs in the VM (step release-tools): python3 -m unittest discover -s scripts/tests -p 'test_release_tools.py'.
No real keychain, notary profile, Sparkle key or network: every credential tool is a stub on PATH.
"""
import os
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
PREFLIGHT = SCRIPTS / "preflight.sh"
APPCAST_ITEM = SCRIPTS / "appcast-item.sh"

APPCAST = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Roadie</title>
{items}  </channel>
</rss>
"""
ITEM_001 = """    <item>
      <title>Version 0.0.1</title>
      <sparkle:version>20261023.1200</sparkle:version>
      <sparkle:shortVersionString>0.0.1</sparkle:shortVersionString>
      <enclosure url="https://roadie.sstools.co/downloads/Roadie-0.0.1.dmg" length="10" type="application/octet-stream" sparkle:edSignature="x"/>
    </item>
"""

STUBS = {
    # find-identity lists one identity unless STUB_IDENTITY is empty; find-certificate prints a fake PEM.
    "security": """#!/bin/sh
case "$1" in
  find-identity)
    if [ -n "$STUB_IDENTITY" ]; then
      echo "  1) 0123456789ABCDEF \\"$STUB_IDENTITY\\""
      echo "     1 valid identities found"
    else
      echo "     0 valid identities found"
    fi ;;
  find-certificate) echo "-----BEGIN CERTIFICATE-----"; echo "-----END CERTIFICATE-----" ;;
esac
""",
    "openssl": """#!/bin/sh
cat >/dev/null
echo "notAfter=Jan  1 00:00:00 2099 GMT"
""",
    "xcrun": """#!/bin/sh
case "$*" in
  *notarytool*history*) [ "$STUB_NOTARY_OK" = 1 ] ;;
  *) exit 0 ;;
esac
""",
    "gh": "#!/bin/sh\nexit 0\n",
    "generate_keys": "#!/bin/sh\necho 'A public key line'\necho \"$STUB_KEY\"\n",
}
TOOLS = ["hdiutil", "codesign", "spctl", "xmllint", "python3", "tart"]


def write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], cwd=cwd, check=True,
                   capture_output=True)


class PreflightRepo:
    """A throwaway repo holding a copy of preflight.sh, with stubbed tools."""

    def __init__(self, base, marketing="0.0.2", key="PUBKEY", appcast_items=ITEM_001, changelog="0.0.2"):
        self.root = base / "repo"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy(PREFLIGHT, self.root / "scripts" / "preflight.sh")
        (self.root / "project.yml").write_text(
            'name: Roadie\nsettings:\n  base:\n    MARKETING_VERSION: "%s"\n'
            'targets:\n  Roadie:\n    settings:\n      configs:\n        Release:\n'
            '          ROADIE_PUBLIC_ED_KEY: "%s"\n' % (marketing, key))
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## [%s] - 2026-10-24\n\n- x\n" % changelog)
        (self.root / "website").mkdir()
        if appcast_items is not None:
            (self.root / "website" / "appcast.xml").write_text(APPCAST.format(items=appcast_items))
        origin = base / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "fixture")
        git(self.root, "remote", "add", "origin", str(origin))
        self.bin = base / "bin"
        self.bin.mkdir()
        for name, text in STUBS.items():
            write_exec(self.bin / name, text)
        for name in TOOLS:
            write_exec(self.bin / name, "#!/bin/sh\nexit 0\n")
        self.env = {
            "PATH": "%s:/usr/bin:/bin:/usr/sbin:/sbin" % self.bin,
            "HOME": str(base),
            "STUB_IDENTITY": "Developer ID Application: Test (TEAMID1234)",
            "STUB_NOTARY_OK": "1",
            "STUB_KEY": "PUBKEY",
        }

    def run(self, *args, zsh_flags=(), **env):
        e = dict(self.env, **env)
        cmd = ["/bin/zsh", *zsh_flags, str(self.root / "scripts" / "preflight.sh"), "--sparkle-bin", str(self.bin), *args]
        p = subprocess.run(cmd, cwd=self.root, env=e, capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name).resolve()

    def tearDown(self):
        self.tmp.cleanup()

    def repo(self, **kw):
        return PreflightRepo(self.base, **kw)

    def test_all_gates_pass(self):
        code, out, err = self.repo().run("--release", "0.0.2", "--build-number", "20261024.0930")
        self.assertEqual(code, 0, out + err)
        for line in ["PASS  repo: tree clean", "PASS  repo: on main", "PASS  version: MARKETING_VERSION is 0.0.2",
                     "PASS  version: 0.0.2 > appcast 0.0.1", "PASS  tag: v0.0.2 absent locally",
                     "PASS  tag: v0.0.2 absent on origin", "PASS  changelog: ## [0.0.2] present",
                     "PASS  build: 20261024.0930 > appcast 20261023.1200",
                     "PASS  identity: Developer ID Application: Test (TEAMID1234)",
                     "PASS  notary: profile Roadie-notary usable", "PASS  sparkle: keychain key matches project.yml",
                     "PASS  gh: authenticated"]:
            self.assertIn(line, out)
        self.assertRegex(out, r"PASS  identity: certificate valid for \d+ days")
        self.assertNotIn("FAIL", out)

    def test_one_line_per_gate(self):
        _, out, _ = self.repo().run("--credentials-only")
        body = out.split("---")[0].strip().splitlines()
        self.assertTrue(body)
        for line in body:
            self.assertRegex(line, r"^(PASS|FAIL|WARN)  ")

    def test_missing_identity_fails(self):
        code, out, _ = self.repo().run("--credentials-only", STUB_IDENTITY="")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  identity: no Developer ID Application identity", out)

    def test_named_identity_must_exist(self):
        code, out, _ = self.repo().run("--credentials-only", "--identity", "Developer ID Application: Other (X)")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  identity: no Developer ID Application identity named", out)

    def test_missing_notary_profile_fails(self):
        code, out, _ = self.repo().run("--credentials-only", STUB_NOTARY_OK="0")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  notary: profile Roadie-notary not usable", out)

    def test_sparkle_key_mismatch_fails(self):
        code, out, _ = self.repo().run("--credentials-only", STUB_KEY="OTHERKEY")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  sparkle: keychain key does not match project.yml", out)
        self.assertNotIn("OTHERKEY", out)
        self.assertNotIn("PUBKEY", out)

    def test_empty_public_key_fails(self):
        code, out, _ = self.repo(key="").run("--credentials-only")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  sparkle: ROADIE_PUBLIC_ED_KEY empty", out)

    def test_version_not_bumped_fails(self):
        code, out, _ = self.repo(marketing="0.0.1", changelog="0.0.1").run("--release", "0.0.1")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  version: 0.0.1 is not greater than appcast 0.0.1", out)

    def test_marketing_version_mismatch_fails(self):
        code, out, _ = self.repo(marketing="0.0.3").run("--release", "0.0.2")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  version: MARKETING_VERSION is '0.0.3', not 0.0.2", out)

    def test_missing_changelog_section_fails(self):
        code, out, _ = self.repo(changelog="0.0.1").run("--release", "0.0.2")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  changelog: no '## [0.0.2]' in CHANGELOG.md", out)

    def test_build_number_not_greater_fails(self):
        code, out, _ = self.repo().run("--credentials-only", "--build-number", "20261023.1159")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  build: 20261023.1159 is not greater than appcast 20261023.1200", out)

    def test_bad_arguments_exit_2(self):
        r = self.repo()
        self.assertEqual(r.run("--release", "1.2")[0], 2)
        self.assertEqual(r.run("--credentials-only", "--build-number", "2026")[0], 2)

    def test_refuses_xtrace(self):
        code, _, err = self.repo().run("--credentials-only", zsh_flags=("-x",))
        self.assertEqual(code, 2)
        self.assertIn("refusing to run with xtrace", err)


@unittest.skipUnless(shutil.which("hdiutil"), "needs hdiutil (macOS)")
class AppcastItemTests(unittest.TestCase):
    """appcast-item.sh against a fixture DMG holding a minimal .app (no code, just an Info.plist)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.tmp.name).resolve()
        src = cls.base / "src"
        contents = src / "Roadie.app" / "Contents"
        contents.mkdir(parents=True)
        with open(contents / "Info.plist", "wb") as f:
            plistlib.dump({"CFBundleShortVersionString": "0.0.2", "CFBundleVersion": "20261024.0930"}, f)
        cls.dmg = cls.base / "Roadie-0.0.2.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-srcfolder", str(src), "-volname", "Roadie", "-format", "UDZO",
                        "-ov", str(cls.dmg)], check=True)
        cls.size = cls.dmg.stat().st_size
        cls.desc = cls.base / "desc.html"
        cls.desc.write_text("<h3>Added</h3>\n<ul>\n  <li>A &amp; B</li>\n</ul>\n")
        cls.sign = cls.base / "sign_update"
        write_exec(cls.sign, '#!/bin/sh\n[ "$1" = --account ] && [ "$2" = Roadie ] || exit 9\n'
                             'echo "sparkle:edSignature=\\"c2lnbmF0dXJl==\\" length=\\"$(stat -f %z "$3")\\""\n')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_item(self, *args):
        p = subprocess.run(["/bin/zsh", str(APPCAST_ITEM), str(self.dmg), *args], capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr

    def xmllint(self, path):
        return subprocess.run(["xmllint", "--noout", str(path)], capture_output=True, text=True)

    def test_dry_run_item_is_valid_xml_with_checked_length(self):
        code, out, err = self.run_item("--version", "0.0.2", "--dry-run", "--signature-stub", "--description",
                                       str(self.desc))
        self.assertEqual(code, 0, err)
        self.assertIn("<sparkle:version>20261024.0930</sparkle:version>", out)
        self.assertIn("<sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>", out)
        self.assertIn('url="https://roadie.sstools.co/downloads/Roadie-0.0.2.dmg"', out)
        self.assertIn("https://roadie.sstools.co/changelog.html#v0-0-2", out)
        self.assertIn('length="%d"' % self.size, out)
        self.assertIn("<li>A &amp; B</li>", out)
        feed = self.base / "dry.xml"
        feed.write_text(APPCAST.format(items=out + "\n"))
        r = self.xmllint(feed)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_wrong_version_is_refused(self):
        code, _, err = self.run_item("--version", "0.0.3", "--dry-run", "--signature-stub")
        self.assertNotEqual(code, 0)
        self.assertIn("the app says 0.0.2, not 0.0.3", err)

    def test_prepends_signed_item_and_preflight_reads_it(self):
        repo = PreflightRepo(self.base / "pf")
        feed = repo.root / "website" / "appcast.xml"
        code, out, err = self.run_item("--version", "0.0.2", "--appcast", str(feed), "--sign-update", str(self.sign),
                                       "--description", str(self.desc))
        self.assertEqual(code, 0, err)
        text = feed.read_text()
        self.assertLess(text.index("<sparkle:version>20261024.0930"), text.index("<sparkle:version>20261023.1200"))
        self.assertIn('sparkle:edSignature="c2lnbmF0dXJl=="', text)
        self.assertEqual(re.findall(r'length="(\d+)"', text)[0], str(self.size))
        self.assertEqual(self.xmllint(feed).returncode, 0)
        # A second run for the same version is refused.
        self.assertNotEqual(self.run_item("--version", "0.0.2", "--appcast", str(feed), "--sign-update",
                                          str(self.sign))[0], 0)
        # preflight.sh parses what appcast-item.sh wrote: 0.0.2 / 20261024.0930 is now the newest.
        git(repo.root, "commit", "-q", "-am", "appcast")
        code, out, _ = repo.run("--release", "0.0.2", "--build-number", "20261024.0930")
        self.assertIn("FAIL  version: 0.0.2 is not greater than appcast 0.0.2", out)
        self.assertIn("FAIL  build: 20261024.0930 is not greater than appcast 20261024.0930", out)


if __name__ == "__main__":
    unittest.main()
