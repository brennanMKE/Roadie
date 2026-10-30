"""Tests for scripts/ui_timeout.py (#0212). Stdlib only: python3 -m unittest discover -s scripts/tests -p 'test_ui_timeout.py'"""
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "ui_timeout.py"
spec = importlib.util.spec_from_file_location("ui_timeout", SCRIPT)
ut = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ut)

# The tail of run 20261029-195714-39620's ui-tests.log: cut off at 1200 s inside a test (exit 124).
CUT_OFF = """Test Suite 'VisualizationUITests' started at 2026-10-30 03:21:40.100.
Test Case '-[RoadieUITests.VisualizationUITests testOverlayShowsTheSong]' started (Iteration 1 of 2).
Test Case '-[RoadieUITests.VisualizationUITests testOverlayShowsTheSong]' passed (7.611 seconds).
Test Case '-[RoadieUITests.VisualizationUITests testOverlayStaysUpWhilePaused]' started (Iteration 1 of 2).
    t =     0.92s Waiting 10.0s for "main.play" Any to exist
** BUILD INTERRUPTED **
"""


class UITimeoutTests(unittest.TestCase):
    def test_limit_is_sized_from_the_work(self):
        self.assertEqual(ut.limit(filtered=True, coverage=False, skins="base"), 1200)   # per-issue run: unchanged
        self.assertEqual(ut.limit(filtered=True, coverage=True, skins="base"), 1800)
        self.assertEqual(ut.limit(filtered=False, coverage=False, skins="base"), 2700)
        # The run that timed out: the whole suite with coverage (102 tests took 1143 s in run 20261029-191545-21712).
        self.assertEqual(ut.limit(filtered=False, coverage=True, skins="base"), 4050)
        self.assertEqual(ut.limit(filtered=False, coverage=True, skins="all"), 4950)  # the milestone-end run

    def test_limit_has_a_cap(self):
        old = ut.ALL_SKINS_SECS
        try:
            ut.ALL_SKINS_SECS = 10_000
            self.assertEqual(ut.limit(filtered=False, coverage=True, skins="all"), ut.CAP_SECS)
        finally:
            ut.ALL_SKINS_SECS = old

    def test_report_names_the_running_test_and_the_limit(self):
        log = "".join(f"Test Case '-[RoadieUITests.MainWindowUITests test{i}]' started (Iteration 1 of 2).\n"
                      f"Test Case '-[RoadieUITests.MainWindowUITests test{i}]' passed (3.0 seconds).\n" for i in range(93))
        line = ut.report(log + CUT_OFF, 1200, 1203)
        self.assertTrue(line.startswith("TIMEOUT  ui-tests ran out of time"), line)
        self.assertIn("stopped after 1203 s at its 1200 s limit", line)
        self.assertIn("94 tests finished", line)
        self.assertIn("running VisualizationUITests.testOverlayStaysUpWhilePaused", line)
        self.assertNotIn("prompt", line)

    def test_report_between_tests(self):
        log = ("Test Case '-[RoadieUITests.SmokeUITests testA]' started.\n"
               "Test Case '-[RoadieUITests.SmokeUITests testA]' failed (4.0 seconds).\n")
        self.assertIn("1 tests finished, between tests", ut.report(log, 1200, 1200))
        self.assertIn("0 tests finished, between tests", ut.report("", 1200, 1200))


if __name__ == "__main__":
    unittest.main()
