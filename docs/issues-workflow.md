# Issues workflow

How Roadie's issues move from filed to resolved, as revised on 2026-10-18 and 2026-10-19, and why.  The verify-runner change (implementers never see build or test logs) is explained in [verify-runner-plan.md](verify-runner-plan.md). The rules live in [issues/Issues.md](../issues/Issues.md) (authoritative) and [docs/testing-in-vm.md](testing-in-vm.md); this page explains the shape and the measured benefits.

## The pipeline

Every issue goes through three phases, each in a fresh subagent dispatched by an orchestrator session. The orchestrator never does phase work itself: it picks issues, dispatches, records usage, keeps milestone tables current and runs the milestone-end check.

| Phase | Model · effort | Does | Status after |
|---|---|---|---|
| 1. Plan | Opus · medium | Reads the issue and current code, writes `## Plan`: files, approach, tests by name, which tier verifies it, a host checklist. No code. | `open` |
| 2. Implement | **Opus · low** (medium after a bounce or bail) | Follows the plan and edits code. For every build or test run it ends its turn with a `VERIFY:` request and is continued with the runner's short report; after a pass it commits the code and drafts Root cause / Fix / Verification / Files changed. | `in-progress` |
| 2v. Verify | **Haiku · low** | Runs the requested `scripts/verify.sh` command and returns its report verbatim. Never reads logs, edits or retries. | — |
| 3. Review | Opus · medium | Reads the diff, re-runs verification itself on `--head`, then resolves or bounces. Only the reviewer sets `resolved`. | `resolved` or `open` |

`model` and `effort` are passed explicitly on every dispatch, and the work log records both. Fable is used only when the user asks. Nobody but the user sets `closed`.

Plans are written close to when the issue is worked, against the code as it stands, and name the tests to add. A low-effort implementer does well with a concrete plan and poorly when it has to explore.

## Keeping logs out of context

A VM run prints thousands of lines: every package's build and every test's start and finish. Before 2026-10-19 that output streamed into the implementer's context. Implementers then read logs on 3–4 turns per issue on average, and every later turn re-read all of it from cache.

Now:

- **`scripts/verify.sh` wraps the run.** The full output goes to `build/vm-tests/<run-id>/run.out`. The exit code says pass or fail. On a pass it prints about five lines: run id, step count, test total, tier, audio, and the `--expect` result. On a failure it prints only the relevant lines, at most 60: failing steps, compiler errors, failing tests with their values, and crashes.
- **A Haiku runner runs it.** Running a script and copying its output back is mechanical, so it goes to the cheapest model. The implementer asks for a run with a `VERIFY:` line. The orchestrator dispatches the runner, then continues the same implementer (its context intact) with the report. The implementer only ever sees that report.
- **`--expect` replaces "find your test in the log".** The script checks that every test the change added ran and passed, so nobody has to search a 2,600-line log for the name.

The loop repeats until a pass, which takes at most three failed runs before a bail. The reviewer runs `scripts/verify.sh --head` itself; its report is just as short.

## Milestones

Every open issue belongs to a milestone with an umbrella issue (Module `Milestone`) whose `## Children` table the orchestrator keeps current. Work goes milestone by milestone; follow-ups found along the way are filed under the milestone they came from. When a milestone's last child is resolved, the orchestrator runs the full tier once on `--head` and records it on the umbrella. Each failure becomes a new cleanup issue under the milestone; resolved children are not reopened.

Issues that need what agents can't do (the user's Mac, the live Music Assistant server, AirPlay hardware, a decision) get a dated note saying what they wait on and stay open. Every resolved issue carries a host checklist for the user, who closes it after checking.

## Verification

All builds, tests and app launches run in a fresh, muted Tart VM through `scripts/run-tests-vm.sh`; never on the host, and never with audio reaching the speakers.

| Mode | When | What runs | Typical time |
|---|---|---|---|
| `--build-only` | Implementer's runner, after editing, before a full run | Both packages with their tests, then the app. Stops early and prints `ERRORS` with `file:line:col` lines. Never counts as verification. | 1.6 min |
| Fast tier (default) | Every implementation and every review | Build stage, unit tests that reuse it (`--skip-build`), the app checks, `--launch` when the plan asks | 2.6 min |
| Full tier (`--full`) | Changes to code a slow test guards (skin-library indexing, AudioCore real-time playback), and each milestone end | Fast tier plus the slow tests: three 100k-row skin-library tests and the real-time audio tests | 3.0 min |

Agents run every mode through `scripts/verify.sh` (same options plus `--expect`). How results are read:

- Every run writes `build/vm-tests/<run-id>/summary.txt`, the same lines it prints: `==> PASS/FAIL/SKIP` per step, `TIER`, `BUILD`/`ERRORS`, `INFRA`, `AUDIO`, the `Test run with …` counts and the exit code. Quote from it; never re-run only to recapture output.
- Exit codes: 0 passed, 1 a step or the audio check failed, 2 bad arguments, 3 infrastructure (the guest was lost or didn't boot; rerun, it isn't the code).
- New tests must appear by name in the log as passed.
- A failure in code the change can't affect: re-run once and record both; if it recurs, it's a flaky-test issue for the tooling milestone, not part of this issue.
- `--stress N --stress-filter F --stress-package SkinKit|PlayerKit [--load]` loops one test or suite to prove a flake is gone.

## Running things in parallel

Two VM runs may run at once (two guests; since #0095 a run never deletes a live run's clone). A review or milestone run tests `--head`, so it doesn't see the working tree, and the next issue's implementation can start alongside it. Two implementations can't overlap: they share one working tree. Planning needs no VM, so several issues can be planned at once while one is implemented.

## Tracking

The orchestrator appends a work-log row per phase (and one `verify` row per runner), computed by `scripts/worklog.py` from the subagent's transcript:

| Date | Phase | Model | Effort | Wall | VM | Turns | Output | Cache read | Cache write | Cost | Outcome |
|---|---|---|---|---|---|---|---|---|---|---|---|

Wall is the subagent's elapsed time minus any idle time between handing back and being continued, VM the time inside VM runs (count and minutes), model time the difference. Output tokens are estimated (characters / 4), because transcripts record only a stream-start snapshot. `scripts/worklog.py --scan` measures every transcript, which is how baselines are built.

## Benefits

Measured from subagent transcripts and VM logs: 61 Sonnet-medium implementations from 2026-10-12 to 10-17 (before), the 10-issue Opus-low experiment on 2026-10-18, and 12 issues on 2026-10-19 after the test-loop changes.

| Median | Before | Opus low (10-18) | + test-loop changes (10-19) |
|---|---|---|---|
| Implementer model time (wall − VM) | 3.5 min | 2.2 min | 1.7 min |
| Implementer turns | 23 | 14 | 13.5 |
| Implementer cost | $0.61 | $0.59 | $0.53 |
| Fast VM run (passing) | 1.5–2.1 min¹ | 3.0 min | 2.6 min |
| Failed compile, time to error | a full run | a full run | 1.6 min (`--build-only`) |
| Runs spoiled by flaky tests | — | 7 of 33 | 4 of 53, all before the fix; 0 of the 42 runs after it |
| Bounced in review | about 15% | 0 of 10 | 0 of 11 |
| Cost per issue, plan + implement + review | — | $1.71 | $1.49 |

¹ A smaller test suite then; not comparable.

- **Model work got faster and cheaper.** Opus at low effort uses about half the tokens of Sonnet at medium, which offsets its doubled price, and turns fell by about 40%.
- **No loss in quality.** 21 implementations in a row passed review first time, and reviewers still found real follow-ups (each filed as its own issue).
- **The test loop is shorter and trustworthy.** Fast runs dropped from 3.0 to 2.6 minutes; SkinLibrary's unit tests from 10.3 s to 0.5 s; a compile error costs 1.6 minutes instead of a full run; and since the two flaky tests were fixed, no run has failed for a reason unrelated to the change.
- **Overlap became safe.** Reviews and milestone checks run on `--head` alongside the next implementation; concurrent runs no longer kill each other.
- **Per-issue wall time held steady (about 14 minutes for implement + review)** even though the 10-19 issues were tooling changes that deliberately ran extra verification (both tiers, stress loops, induced failures). Ordinary feature issues should see the full per-run savings.
- **Visible cost and speed.** Every phase's effort, wall time, VM time and cost is in the issue's work log, so changes like these can be judged on numbers.

Worth considering next: caching builds between VM runs (the build stage is about half of every run), reusing the implementer's run in review when the commit is unchanged, and trying review at high effort.
