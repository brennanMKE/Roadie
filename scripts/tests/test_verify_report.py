"""Tests for scripts/verify.sh --report with --expect-fail (#0201), on fabricated results directories.

Runs in the VM (step release-tools): python3 -m unittest discover -s scripts/tests -p 'test_*.py'. No VM needed:
--report rebuilds the report from a finished run without running anything.
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

VERIFY = Path(__file__).resolve().parent.parent / "verify.sh"

PASSING = "✔ Test firstRowIsZero() passed after 0.001 seconds.\n✔ Test anotherOne() passed after 0.001 seconds.\n"


class ExpectFailTests(unittest.TestCase):
    def results(self, log, summary_fail=True):
        d = Path(tempfile.mkdtemp())
        lines = ["==> TIER  fast"]
        lines.append("==> FAIL  playerkit-tests (exit 1)" if summary_fail else "==> PASS  playerkit-tests")
        lines.append("==> Cleaning up (exit %d)" % (1 if summary_fail else 0))
        (d / "summary.txt").write_text("\n".join(lines) + "\n")
        (d / "playerkit-tests.log").write_text(log)
        return d

    def run_verify(self, d, *args):
        return subprocess.run(["/bin/zsh", str(VERIFY), "--report", str(d), *args],
                              capture_output=True, text=True)

    def test_expect_fail_passes_when_only_the_named_test_fails(self):
        d = self.results(PASSING + "✘ Test rowIndexIsThePosition() recorded an issue at X.swift:3:5\n"
                         "✘ Test rowIndexIsThePosition() failed after 0.002 seconds with 1 issue.\n")
        r = self.run_verify(d, "--expect-fail", "rowIndexIsThePosition")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("==> EXPECT-FAIL  all 1 expected test(s) failed as required", r.stdout)

    def test_expect_fail_fails_when_the_test_passed(self):
        d = self.results(PASSING + "✔ Test rowIndexIsThePosition() passed after 0.001 seconds.\n", summary_fail=False)
        r = self.run_verify(d, "--expect-fail", "rowIndexIsThePosition")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("passed or never ran: rowIndexIsThePosition", r.stdout)

    def test_expect_fail_fails_when_another_test_fails_too(self):
        d = self.results(PASSING + "✘ Test rowIndexIsThePosition() failed after 0.002 seconds with 1 issue.\n"
                         "✘ Test somethingElse() failed after 0.002 seconds with 1 issue.\n")
        r = self.run_verify(d, "--expect-fail", "rowIndexIsThePosition")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("other tests failed too: somethingElse", r.stdout)

    def test_name_in_both_lists_is_a_usage_error(self):
        d = self.results(PASSING)
        r = self.run_verify(d, "--expect", "rowIndexIsThePosition", "--expect-fail", "rowIndexIsThePosition")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
