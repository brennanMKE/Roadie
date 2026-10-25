"""Tests for scripts/verify.sh --report with --expect-fail (#0201), on fabricated results directories.

Runs in the VM (step release-tools): python3 -m unittest discover -s scripts/tests -p 'test_verify_report.py'. No VM needed:
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

    def test_expect_fail_fails_when_the_step_also_crashed(self):
        d = self.results(PASSING + "✘ Test rowIndexIsThePosition() failed after 0.002 seconds with 1 issue.\n"
                         "PlayerKit/Foo.swift:12: Fatal error: Unexpectedly found nil\n"
                         "error: Exited with unexpected signal code 4\n")
        r = self.run_verify(d, "--expect-fail", "rowIndexIsThePosition")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("crash in step playerkit-tests", r.stdout)

    def test_expect_fail_matches_xctest_names_exactly(self):
        d = self.results("Test Case '-[RoadieTests.FooTests testBar]' failed (0.002 seconds).\n"
                         "Test Case '-[RoadieTests.FooTests testBarBaz]' passed (0.001 seconds).\n")
        self.assertEqual(self.run_verify(d, "--expect-fail", "testBar").returncode, 0)
        r = self.run_verify(d, "--expect-fail", "testBarBaz")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("passed or never ran: testBarBaz", r.stdout)

    def test_build_failure_is_not_an_expected_failure(self):
        d = self.results("error: compile failed\n")
        (d / "summary.txt").write_text("==> FAIL  playerkit-build (exit 1)\n==> SKIP  playerkit-tests (build failed)\n"
                                       "==> BUILD  failed: 1 step(s) skipped\n==> Cleaning up (exit 1)\n")
        r = self.run_verify(d, "--expect-fail", "rowIndexIsThePosition")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_name_in_both_lists_is_a_usage_error(self):
        d = self.results(PASSING)
        r = self.run_verify(d, "--expect", "rowIndexIsThePosition", "--expect-fail", "rowIndexIsThePosition")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
