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


class UIReportTests(unittest.TestCase):
    """#0200: a failed ui-tests step names the test, its assertion, the screenshot folder and the xcresult."""

    def results(self, failed_name="testFoo", with_attachments=True, rc=1):
        d = Path(tempfile.mkdtemp())
        (d / "summary.txt").write_text(
            "==> PASS  app-build\n==> PASS  ui-build\n==> FAIL  ui-tests (exit %d)\n"
            "==> TIER  fast\n==> Cleaning up (exit 1)\n" % rc)
        (d / "ui-tests.log").write_text(
            "Test Case '-[RoadieUITests.SmokeUITests testBar]' passed (3.1 seconds).\n"
            "/Users/admin/src/Tests/RoadieUITests/SmokeUITests.swift:41: warning: unused variable 'x'\n"
            "/Users/admin/src/Tests/RoadieUITests/SmokeUITests.swift:42: error: -[RoadieUITests.SmokeUITests %s] : "
            "XCTAssertEqual failed: (\"2. A - B\") is not equal to (\"9. wrong\") - pl.row.1 label\n"
            "Test Case '-[RoadieUITests.SmokeUITests %s]' failed (4.2 seconds).\n" % (failed_name, failed_name))
        (d / "ui" / "UITests.xcresult").mkdir(parents=True)
        if with_attachments:
            (d / "ui" / "attachments" / failed_name).mkdir(parents=True)
            (d / "ui" / "attachments" / failed_name / "screen.png").write_bytes(b"png")
        return d

    def run_verify(self, d, *args):
        return subprocess.run(["/bin/zsh", str(VERIFY), "--report", str(d), *args],
                              capture_output=True, text=True)

    def test_report_names_test_assertion_screenshots_and_xcresult(self):
        d = self.results()
        r = self.run_verify(d)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("testFoo", r.stdout)
        self.assertIn("XCTAssertEqual failed", r.stdout)
        self.assertIn("screenshots: %s/" % (d.resolve() / "ui" / "attachments" / "testFoo"), r.stdout)
        self.assertIn("xcresult: %s" % (d.resolve() / "ui" / "UITests.xcresult"), r.stdout)
        self.assertIn("warning: unused variable", r.stdout)
        self.assertLess(len(r.stdout.splitlines()), 60, r.stdout)

    def test_missing_attachments_say_none_exported(self):
        r = self.run_verify(self.results(with_attachments=False))
        self.assertIn("screenshots: none exported (testFoo)", r.stdout)

    def test_timeout_is_reported(self):
        r = self.run_verify(self.results(rc=124))
        self.assertIn("ui-tests timed out (a blocked prompt in the guest?)", r.stdout)

    def test_expect_accepts_names_with_or_without_the_test_prefix(self):
        d = self.results()
        (d / "summary.txt").write_text("==> PASS  ui-tests\n==> TIER  fast\n==> UI  2 tests passed (all classes) on base\n"
                                       "==> Cleaning up (exit 0)\n")
        for name in ("bar", "testBar"):
            r = self.run_verify(d, "--expect", name, "--exit", "0")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("==> UI  2 tests passed", r.stdout)


if __name__ == "__main__":
    unittest.main()
