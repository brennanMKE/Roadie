#!/usr/bin/env python3
"""ui_timeout.py: the ui-tests step's time limit, and what a timed-out step was doing (#0212). Stdlib only, run with -I.

  ui_timeout.py limit [--filtered] [--coverage] [--skins base|all]   prints the limit in seconds
  ui_timeout.py report LOG LIMIT ELAPSED                             prints the TIMEOUT summary line

The limit is sized from the work, with a cap so a real hang still fails. A filtered run (a few classes, per issue)
keeps the old 20 min. The whole suite (about 111 tests, 19 min with coverage in run 20261029-191545-21712's 102)
gets 45 min; coverage instrumentation makes every test slower (x1.5); `--ui-skins all` adds the six other skins'
smoke tests (+15 min). Nothing goes over 90 min.
"""
import argparse
import re
import sys

FILTERED_SECS = 1200
UNFILTERED_SECS = 2700
COVERAGE_FACTOR = 1.5
ALL_SKINS_SECS = 900
CAP_SECS = 5400

STARTED = re.compile(r"Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' started")
ENDED = re.compile(r"Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' (passed|failed)")


def limit(filtered, coverage, skins):
    secs = FILTERED_SECS if filtered else UNFILTERED_SECS
    if coverage:
        secs *= COVERAGE_FACTOR
    if skins == "all":
        secs += ALL_SKINS_SECS
    return int(min(secs, CAP_SECS))


def progress(log_text):
    """(finished test count, the test that was running or None). A retried test counts once per finished attempt."""
    finished, running = 0, None
    for line in log_text.splitlines():
        m = STARTED.search(line)
        if m:
            running = f"{m.group(1)}.{m.group(2)}"
            continue
        m = ENDED.search(line)
        if m:
            finished += 1
            if running == f"{m.group(1)}.{m.group(2)}":
                running = None
    return finished, running


def report(log_text, limit_secs, elapsed_secs):
    finished, running = progress(log_text)
    where = f"running {running}" if running else "between tests"
    return (f"TIMEOUT  ui-tests ran out of time: stopped after {elapsed_secs} s at its {limit_secs} s limit, "
            f"{finished} tests finished, {where}. Not a test failure; see docs/testing-in-vm.md for the limit")


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    lp = sub.add_parser("limit")
    lp.add_argument("--filtered", action="store_true")
    lp.add_argument("--coverage", action="store_true")
    lp.add_argument("--skins", default="base", choices=("base", "all"))
    rp = sub.add_parser("report")
    rp.add_argument("log")
    rp.add_argument("limit", type=int)
    rp.add_argument("elapsed", type=int)
    a = ap.parse_args(argv)
    if a.cmd == "limit":
        print(limit(a.filtered, a.coverage, a.skins))
    else:
        try:
            text = open(a.log, errors="replace").read()
        except OSError:
            text = ""
        print(report(text, a.limit, a.elapsed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
