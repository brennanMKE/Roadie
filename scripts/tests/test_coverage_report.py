"""Tests for scripts/coverage_report.py (#0212). Stdlib only: python3 -m unittest discover -s scripts/tests -p 'test_coverage_report.py'"""
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "coverage_report.py"
# Real `llvm-cov report` output from run 20261024-232610-35692 (one test binary per package; llvm-cov stripped the
# common prefix /Users/admin/src/Packages/<P>/Sources/, so rows read `AudioCore/…`, not `Sources/AudioCore/…`).
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "coverage"
spec = importlib.util.spec_from_file_location("coverage_report", SCRIPT)
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

HEADER = ("Filename                      Regions    Missed Regions     Cover   Functions  Missed Functions  Executed       "
          "Lines      Missed Lines     Cover    Branches   Missed Branches     Cover\n" + "-" * 80 + "\n")


def row(path, lines, missed):
    return f"{path}  10  2  80.00%  5  1  80.00%  {lines}  {missed}  {100 * (lines - missed) / lines:.2f}%  0  0  -\n"


def llvm(rows):
    return HEADER + "".join(row(*r) for r in rows) + "-" * 80 + "\nTOTAL  10  2  80.00%  5  1  80.00%  1  1  0.00%  0  0  -\n"


def xccov(files, *more_targets):
    """`files` are Roadie.app's; each of `more_targets` is (target name, files)."""
    targets = [("Roadie.app", files), *more_targets]
    return json.dumps({"targets": [{"name": name, "files": [
        {"path": p, "name": Path(p).name, "executableLines": l, "coveredLines": c} for p, l, c in fs]}
        for name, fs in targets]})


class CoverageReportTests(unittest.TestCase):
    def run_main(self, llvm_texts, xccov_texts, floors, tier="fast"):
        d = Path(tempfile.mkdtemp())
        args = ["--out", str(d / "coverage"), "--tier", tier]
        for pkg, text in llvm_texts.items():
            (d / f"{pkg}.txt").write_text(text)
            args += ["--llvm", f"{pkg}={d / f'{pkg}.txt'}"]
        for i, text in enumerate(xccov_texts):
            (d / f"app{i}.json").write_text(text)
            args += ["--xccov", str(d / f"app{i}.json")]
        (d / "floors.tsv").write_text(floors)
        args += ["--floors", str(d / "floors.tsv")]
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cr.main(args)
        return rc, buf.getvalue(), d / "coverage"

    def test_aggregates_per_target(self):
        skin = llvm([
            ("/src/Packages/SkinKit/Sources/SkinKit/A.swift", 100, 10),
            ("/src/Packages/SkinKit/Sources/SkinKit/B.swift", 100, 30),
            ("/src/Packages/SkinKit/Sources/SkinMuseumStub/S.swift", 100, 100),
            ("/src/Packages/SkinKit/Tests/SkinKitTests/T.swift", 100, 0),
        ])
        app_unit = xccov([("/src/App/PlayerModel.swift", 200, 100), ("/src/RoadieTests/X.swift", 50, 50)])
        app_ui = xccov([("/src/App/PlayerModel.swift", 200, 150), ("/src/App/Other.swift", 100, 0)])
        rc, out, d = self.run_main({"SkinKit": skin}, [app_unit, app_ui], "SkinKit\t50\nApp\t40\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("coverage: SkinKit 80.0%", out)          # 160 of 200, the stub and tests left out
        self.assertIn("coverage: SkinMuseumStub 0.0%", out)
        self.assertIn("coverage: App 50.0%", out)              # max per file across bundles: 150 of 300
        self.assertIn("SkinKit 80%  App 50%", (d / "packages.txt").read_text())  # stub not in the package number
        self.assertIn("| SkinKit | SkinKit | 200 | 160 | 80.0% | 50% | ok |", (d / "report.md").read_text())

    def test_lowest_lists_twenty_files_over_forty_lines(self):
        rows = [(f"/src/Packages/PlayerKit/Sources/AudioCore/F{i:02d}.swift", 100, i) for i in range(30)]
        rows.append(("/src/Packages/PlayerKit/Sources/AudioCore/Tiny.swift", 40, 40))
        rc, out, d = self.run_main({"PlayerKit": llvm(rows)}, [], "")
        lines = (d / "lowest.txt").read_text().splitlines()
        self.assertEqual(len(lines), 20)
        self.assertTrue(lines[0].endswith("Packages/PlayerKit/Sources/AudioCore/F29.swift"), lines[0])
        self.assertNotIn("Tiny.swift", "\n".join(lines))
        self.assertTrue(lines[0].lstrip().startswith("71.0%"), lines[0])

    def test_floor_breach_exits_one(self):
        rows = [("/src/Packages/PlayerKit/Sources/SendspinKit/A.swift", 100, 50)]
        rc, out, d = self.run_main({"PlayerKit": llvm(rows)}, [], "SendspinKit\t85\n")
        self.assertEqual(rc, 1)
        self.assertIn("coverage: FLOOR SendspinKit 50.0% < 85%", out)
        self.assertIn("**under**", (d / "report.md").read_text())

    def test_audiocore_floor_depends_on_tier(self):
        rows = [("/src/Packages/PlayerKit/Sources/AudioCore/A.swift", 100, 25)]
        rc_fast, out_fast, _ = self.run_main({"PlayerKit": llvm(rows)}, [], "AudioCore\t70\n", tier="fast")
        rc_full, out_full, _ = self.run_main({"PlayerKit": llvm(rows)}, [], "AudioCore\t70\n", tier="full")
        self.assertEqual(rc_fast, 0, out_fast)
        self.assertEqual(rc_full, 1)
        self.assertIn("coverage: FLOOR AudioCore 75.0% < 80%", out_full)

    def test_real_llvm_cov_report_with_common_prefix_stripped(self):
        player = (FIXTURES / "PlayerKit-AudioCoreTests.llvm-cov.txt").read_text()
        skin = (FIXTURES / "SkinKit-SkinBrowserTests.llvm-cov.txt").read_text()
        files = cr.parse_llvm_report(player)
        self.assertEqual(len(files), 41)                       # every row but the header and TOTAL
        self.assertEqual(files["AudioCore/Player.swift"], (694, 660))
        rc, out, d = self.run_main({"PlayerKit": player, "SkinKit": skin}, [], "AudioCore\t70\nSkinMuseum\t85\n")
        # Before the fix every row was dropped (no `Sources/` in the path) and both floors came back MISSING.
        self.assertEqual(rc, 0, out)
        self.assertNotIn("MISSING", out)
        self.assertIn("coverage: CAtomics 0.0%", out)           # a C shim: reported, not in the package number
        self.assertIn("coverage: PlayerKitTestFixtures 94.0%", out)
        # AudioCore: TOTAL 4207 lines / 269 missed, less CAtomics (9/9) and PlayerKitTestFixtures (50/3).
        self.assertIn(f"coverage: AudioCore {100 * (4207 - 9 - 50 - (269 - 9 - 3)) / (4207 - 9 - 50):.1f}%", out)
        for target in ("SkinKit", "SkinLibrary", "SkinBrowser", "SkinMuseum"):
            self.assertIn(f"coverage: {target} ", out)
        self.assertIn("| AudioCore | PlayerKit |", (d / "report.md").read_text())
        self.assertIn("Packages/PlayerKit/Sources/AudioCore/", (d / "lowest.txt").read_text())

    def test_absolute_and_stripped_paths_key_the_same_target(self):
        self.assertEqual(cr.package_target("/Users/admin/src/Packages/SkinKit/Sources/SkinKit/A/B.swift"),
                         ("SkinKit", "Sources/SkinKit/A/B.swift"))
        self.assertEqual(cr.package_target("SkinKit/A/B.swift"), ("SkinKit", "Sources/SkinKit/A/B.swift"))
        self.assertEqual(cr.package_target("B.swift"), (None, "B.swift"))  # a one-target prefix: unattributable

    def test_floored_target_with_nothing_measured_exits_one(self):
        rows = [("/src/Packages/PlayerKit/Sources/AudioCore/A.swift", 100, 0)]
        rc, out, d = self.run_main({"PlayerKit": llvm(rows)}, [], "AudioCore\t70\nWindowDocking\t85\n")
        self.assertEqual(rc, 1)
        self.assertIn("coverage: MISSING WindowDocking (no files measured)", out)
        self.assertNotIn("FLOOR", out)

    def test_app_test_support_is_left_out(self):
        app = xccov([("/src/App/PlayerModel.swift", 100, 50), ("/src/App/TestSupport/PanelStandIns.swift", 100, 100)])
        rc, out, d = self.run_main({}, [app], "App\t40\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("coverage: App 50.0%", out)              # 66.7% if the test-only stand-ins counted
        self.assertIn("| App | App | 100 | 50 | 50.0% | 40% | ok |", (d / "report.md").read_text())

    def test_file_in_app_and_test_bundle_counts_under_app(self):
        # Run 20261029-191545-21712: AXID.swift is under Roadie.app and RoadieUITests.xctest in the UI bundle.
        axid = "/src/App/Accessibility/AXID.swift"
        after = xccov([(axid, 15, 5)], ("RoadieUITests.xctest", [(axid, 15, 14)]))
        before = json.dumps({"targets": list(reversed(json.loads(after)["targets"]))})
        self.assertEqual(cr.parse_xccov(after)[axid], (15, 5))
        self.assertEqual(cr.parse_xccov(before)[axid], (15, 5))
        only_test = xccov([], ("RoadieUITests.xctest", [(axid, 15, 14)]), ("Other.xctest", [(axid, 15, 3)]))
        self.assertEqual(cr.parse_xccov(only_test)[axid], (15, 14))  # no app row: the first one
        rc, out, _ = self.run_main({}, [after], "App\t30\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("coverage: App 33.3%", out)

    def run_partial(self, reason, app_floor="60"):
        skin = llvm([("/src/Packages/SkinKit/Sources/SkinKit/A.swift", 100, 10)])
        app = xccov([("/src/App/PlayerModel.swift", 100, 28)])   # the unit tests' share only
        d = Path(tempfile.mkdtemp())
        (d / "s.txt").write_text(skin)
        (d / "a.json").write_text(app)
        (d / "f.tsv").write_text(f"SkinKit\t85\nApp\t{app_floor}\n")
        args = ["--out", str(d / "coverage"), "--llvm", f"SkinKit={d / 's.txt'}", "--xccov", str(d / "a.json"),
                "--floors", str(d / "f.tsv")]
        if reason:
            args += ["--partial", f"App={reason}"]
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cr.main(args)
        return rc, buf.getvalue(), d / "coverage"

    def test_partial_app_is_reported_not_a_floor_breach(self):
        # Run 20261029-195714-39620: ui-tests timed out, so the UI bundle had no coverage and App came out at 27.5%.
        rc, out, d = self.run_partial("ui-tests timed out")
        self.assertEqual(rc, 0, out)
        self.assertIn("coverage: PARTIAL App 28.0% (floor 60% not checked: ui-tests timed out)", out)
        self.assertNotIn("FLOOR App", out)
        self.assertIn("App 28% (partial)", (d / "packages.txt").read_text())
        report = (d / "report.md").read_text()
        self.assertIn("| App | App | 100 | 28 | 28.0% | 60% | partial |", report)
        self.assertIn("**Partial:** App's number is incomplete (ui-tests timed out)", report)

    def test_partial_app_keeps_other_floors(self):
        d = Path(tempfile.mkdtemp())
        (d / "s.txt").write_text(llvm([("/src/Packages/SkinKit/Sources/SkinKit/A.swift", 100, 50)]))
        (d / "f.tsv").write_text("SkinKit\t85\nApp\t60\n")
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cr.main(["--out", str(d / "c"), "--llvm", f"SkinKit={d / 's.txt'}", "--floors", str(d / "f.tsv"),
                          "--partial", "App=ui-tests failed (1)"])
        self.assertEqual(rc, 1, buf.getvalue())
        self.assertIn("coverage: FLOOR SkinKit 50.0% < 85%", buf.getvalue())
        self.assertNotIn("MISSING App", buf.getvalue())   # no App rows at all: partial, not MISSING
        self.assertIn("coverage: PARTIAL App (nothing measured; floor not checked: ui-tests failed (1))", buf.getvalue())

    def test_without_partial_the_app_floor_still_fails(self):
        rc, out, _ = self.run_partial(None)
        self.assertEqual(rc, 1)
        self.assertIn("coverage: FLOOR App 28.0% < 60%", out)


if __name__ == "__main__":
    unittest.main()
