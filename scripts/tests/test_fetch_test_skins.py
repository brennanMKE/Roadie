"""Tests for scripts/test_skins.py, the manifest reader behind fetch-test-skins.sh (#0198)."""
import hashlib
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import test_skins  # noqa: E402

GOOD = b"good skin bytes"
GOOD_MD5 = hashlib.md5(GOOD).hexdigest()


class FetchTestSkinsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write_manifest(self, text):
        path = os.path.join(self.dir, "m.tsv")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def test_parse_manifest_rows(self):
        real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test-skins.tsv")
        rows = test_skins.parse_manifest(real)
        self.assertEqual(len(rows), 7)
        self.assertEqual(rows[0]["name"], "base-2.91")
        self.assertEqual(rows[0]["museum_id"], "S119636")
        self.assertEqual(rows[0]["md5"], "5e4f10275dcb1fb211d4a8b4f1bda236")
        self.assertTrue(rows[0]["why"])
        path = self.write_manifest("# comment\n\na\tS1\t%s\twhy a\nb\tS2\t%s\n" % (GOOD_MD5, "0" * 32))
        rows = test_skins.parse_manifest(path)
        self.assertEqual([r["name"] for r in rows], ["a", "b"])
        self.assertEqual(rows[1]["why"], "")

    def test_check_reports_missing_and_bad_md5(self):
        cache = os.path.join(self.dir, "cache")
        os.mkdir(cache)
        with open(os.path.join(cache, "good.wsz"), "wb") as f:
            f.write(GOOD)
        with open(os.path.join(cache, "wrong.wsz"), "wb") as f:
            f.write(b"edited")
        path = self.write_manifest(
            "good\tS1\t%s\tx\nwrong\tS2\t%s\tx\nabsent\tS3\t%s\tx\n" % (GOOD_MD5, GOOD_MD5, GOOD_MD5))
        results = test_skins.check(test_skins.parse_manifest(path), cache)
        self.assertEqual(results, [("ok", "good"), ("bad-md5", "wrong"), ("missing", "absent")])
        self.assertEqual(test_skins.main(["x", "check", path, cache]), 1)

    def test_rejects_bad_md5_format(self):
        for bad in ("XYZ", "5E4F10275DCB1FB211D4A8B4F1BDA236", "5e4f1027"):
            path = self.write_manifest("a\tS1\t%s\twhy\n" % bad)
            with self.assertRaises(ValueError):
                test_skins.parse_manifest(path)


if __name__ == "__main__":
    unittest.main()
