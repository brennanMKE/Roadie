# Verify runner: keeping build and test logs out of the implementer

Revision plan, 2026-10-19 (commit 9836a04), with the trial's results at the end ([Results](#results-m12-trial-2026-10-19)). The rules live in [issues/Issues.md](../issues/Issues.md) (phase 2 and phase 2v). [issues-workflow.md](issues-workflow.md) covers the workflow as a whole. This page covers why the change was made, how it works, what it should save, and how we'll know.

## Problem

Under the Opus-low workflow, the implementer runs the VM tests itself. A fast-tier run writes about 8,100 lines (924 KB) of build and test output. The Bash tool truncates that, so the implementer never sees all of it. But it still pays for the run in two ways:

- **Log text in context.** Test and log output reaching the implementer had a median of 12k characters per issue before the change (11% of all tool output), and 20k characters on 2026-10-19 (37%). Every later turn re-reads that text from cache.
- **Turns spent digging.** Implementers spent 1.8 to 4.2 tool calls per issue tailing, grepping and re-reading logs to find the run id, the counts, a failing assertion or their new test's name. Each of those turns re-reads the whole context, about 60k tokens, and costs about half a minute of model time.

Reading logs is mechanical work, and it was being done by the most expensive agent in the loop.

## Design

```
orchestrator ──dispatch──▶ implementer (Opus · low)
                              │ edits code, ends turn with
                              │ VERIFY: scripts/verify.sh [--full] [--expect testA,testB]
orchestrator ◀────────────────┘
     │ dispatch
     ▼
runner (Haiku · low) ── runs the command, returns its stdout verbatim + exit code
     │
orchestrator ──SendMessage (same implementer, context intact)──▶ "VERIFY PASS …" or "VERIFY FAIL …"
     │
     └─ loop until the implementer commits and returns DONE, or bails (3 failed runs max)
```

| Piece | Role |
|---|---|
| `scripts/verify.sh` | Wraps `run-tests-vm.sh` with the same options, plus `--expect`. Sends the full output to `build/vm-tests/<run-id>/run.out`; the exit code decides. Prints a short report (below). Retries an INFRA exit (3) once. |
| Implementer, Opus · low | Never runs builds or tests, and never reads `build/vm-tests/`. Asks for runs with a `VERIFY:` line, fixes from the report, commits after a pass, and quotes the pass report in `## Verification`. |
| Runner, Haiku · low | Runs exactly one command and returns its output verbatim. It doesn't read logs, edit, retry or interpret. It's the cheapest model because the task needs no judgement. |
| Orchestrator | Relays each report verbatim, never summarised, to the same implementer through `SendMessage`. Records a `verify` work-log row per runner. Tells the implementer to bail after the third failed run. |
| Reviewer, Opus · medium | Runs `scripts/verify.sh --head` itself, with the same tier and `--expect` list. It may open a failed step's log, because a review needs the diagnosis. |

### The report

A pass, from a real run:

```
==> VERIFY  PASS (exit 0) 20261019-142558-44348: 8 steps passed, 1385 tests in 14 test runs
==> TIER  fast: 100k scale and real-time audio tests skipped (scripts/run-tests-vm.sh --full runs them)
==> AUDIO  silent: no host 'Starting IO' events during the run
==> EXPECT  all 1 expected test(s) passed
==> Results: …/build/vm-tests/20261019-142558-44348
```

A failure contains:

- the `FAIL`, `BUILD`, `ERRORS`, `INFRA` and `AUDIO` lines from `summary.txt`;
- compiler errors as `file:line:col`;
- from each failed test step's log, the `✘` lines, the `↳` lines with the actual values, crashes and fatal errors.

It's capped at 60 lines and also saved as `failure.txt`. A failing test reads, for example:

```
==> playerkit-tests failures:
    ✘ Test pingIsSentEveryIntervalWhileConnected() recorded an issue at ClientConnectionTests.swift:128:9: Expectation failed: rig.transport.pingCount == 2
    ↳ rig.transport.pingCount == 2 → false
    ↳   rig.transport.pingCount → 1
```

`--expect testA,testB` makes the run fail unless each named test ran and passed. This replaces the rule "find your new test's name in the log", which was itself a reason to read logs. `--expect-fail testA` (#0201) is the reverse: the run passes only if those tests failed and nothing else did, which proves a regression test fails before the fix.

## Expected effect

| | Before | Expected |
|---|---|---|
| Test/log text in the implementer's context | 12–20k characters per issue | about 0.5k per run (5 lines on a pass, up to 60 on a failure) |
| Implementer tool calls reading logs | 1.8–4.2 per issue | 0 |
| Implementer turns | 13.5 (median, 10-19) | about 10–11 |
| Implementer cache reads | 0.80M (median) | 10–20% lower |
| Runner cost | — | about $0.01 per run on Haiku |
| Orchestration overhead | — | one dispatch plus one `SendMessage` per run, a few seconds each |

Be realistic about the size of the gain:

- **Tokens:** most of the saving comes from the turns that go away, not from shorter output. It should be a modest cut, not a halving.
- **Wall time:** waiting on the VM (2.6–3 minutes per run) is unchanged.
- **Quality:** the implementer reasons over a clean, complete failure report instead of whatever part of the log it chose to tail.

## How we'll judge it

Run the next several workable issues on the new flow and compare against the 2026-10-19 medians from `scripts/worklog.py --scan`:

1. Implementer turns, cache reads and cost (one `implement` row per issue).
2. Implementer model time. Wall now leaves out the idle gaps between continuations, so it compares directly.
3. Runner rows: count and cost per issue.
4. Bounces in review, especially any where the failure report wasn't enough to diagnose the problem. Each such case is a pattern `verify.sh` should learn to extract.
5. Whether any implementer broke the rule and read logs. Check its transcript for `build/vm-tests`.

Keep the change if turns and cost fall and bounces don't rise. If a failure report repeatedly proves insufficient, extend the filter in `verify.sh` instead of letting implementers read logs again.

## Results: M12 trial, 2026-10-19

### What ran

There were no workable open issues, so five real gaps were filed from TODOs and edge cases in the code as milestone M12 (#0097):

- #0098: BMP fallback decoder;
- #0099: generated base skin;
- #0100: nested playlists;
- #0101: playlist titles;
- #0102: UTF-16 playlists without a BOM.

The #0100 reviewer filed a sixth, #0103 (a cap on nested-playlist fan-out), which went through the same flow. Each issue was planned, implemented with Haiku verification runs, and reviewed.

- **Elapsed time:** filing to the last resolution took 39 minutes (15:01 to 15:40). Reviews and the next implementation overlapped, and up to two VMs ran at once.
- **Outcome:** 6 of 6 issues resolved, none bounced, one real follow-up filed.
- **Milestone-end full tier:** passed (`20261019-154013-16062`, 1428 tests, silent).

The baseline is the 12 Opus-low issues worked earlier on 2026-10-19 (#0083–#0096) under the old flow, in which implementers ran the VM themselves. Figures are medians per issue from `scripts/worklog.py --scan`.

### Implementer (Opus · low)

| | Old flow | Verify runner | Change |
|---|---|---|---|
| Turns | 13.5 | 8.5 | −37% |
| Tool calls | 14.5 | 9 | −38% |
| Calls touching tests or logs | 9.5 | ~0¹ | gone |
| Test/log output reaching the implementer | 20.1k chars (37% of tool output) | ~0 | gone |
| Cache read | 803k | 429k | −47% |
| Output (estimated) | 5.3k | 3.8k | −28% |
| Model time | 1.7 min | 1.1 min | −35% |
| Cost | $0.53 | $0.35 | −34% |
| Implement elapsed, including test runs | 9.0 min (2.75 runs/issue) | 4.1 min (1.33 runs/issue) | see caveats |

¹ The one match per transcript is the implementer reading the `verify.sh` rule in `Issues.md`, not a run or a log.

Every implementer kept the rule: none ran a build or test or opened a log. On a failed run, the fix arrived in 6 seconds (a compile error) and 12 seconds (a failing test), each written from the report alone.

### Runner (Haiku · low)

| | Per run |
|---|---|
| Runs | 8 (6 pass, 2 fail) |
| Turns | 2 |
| Cost | $0.003 (all 8: $0.03) |
| Overhead beyond the VM run | about 6 seconds (2.9 min wall vs 2.8 min in the VM) |
| Wait from runner finishing to implementer resuming | negligible: implementer idle ≈ runner wall |

### Review (Opus · medium, running `verify.sh --head` itself)

| | Old flow | Verify runner |
|---|---|---|
| Test/log output reaching the reviewer | 7.8k chars | 0.6k chars |
| Cache read | 789k | 681k |
| Model time | 0.8 min | 0.4 min |
| Cost | $0.47 | $0.37 |

### Per issue

| | Old flow | Verify runner |
|---|---|---|
| Plan + implement + verify + review cost | $1.49 | $1.07 (−28%) |
| Bounced in review | 0 of 12 | 0 of 6 |

### What the reports caught, and missed

There were two failed runs, both on #0099:

1. **A compile error that `verify.sh` didn't extract.** An `#expect` macro expanded to an ambiguous `==`. Swift reports that as a macro-expansion diagnostic with no `path:line:col` prefix. `run-tests-vm.sh`'s ERRORS block therefore fell back to the log tail, which was mostly a 6 KB "Failed frontend command" line, and the real error wasn't in the report. Fixed the same hour (aff92f7):
   - failed build steps now print each `error:` line with 10 lines of context, which includes the note naming the real file and line;
   - report lines are cut at 300 characters;
   - `verify.sh --report DIR` rebuilds the report from a finished run, so this one didn't have to run again.
2. **An existing test broken by a cache-version bump.** The report had exactly what was needed: the `✘` line, the `↳` values and the path it expected. The implementer fixed the hardcoded `r1` without opening anything.

So one of the two failure reports needed a tooling fix. This is the risk the plan named ("report gaps"). The answer was to fix the filter, not to let implementers read logs, and that worked.

### Analysis

- **The change did what it was meant to.** Build and test output in the implementer's context fell from about 20k characters per issue to zero, and the 9.5 tool calls that ran tests or tailed logs disappeared. Turns fell by about a third, and cache reads, which multiply turns by context size, nearly halved. The plan predicted 10–20% fewer cache reads; the trial saw 47%. Part of the difference is the issue mix (next point). The rest is that without logs in context, each remaining turn is also smaller: about 50k tokens of context per turn against 59k before.
- **Allow for the issue mix.** These six issues were smaller than the baseline's tooling issues. Planning, which this change didn't touch, fell from 12 to 9 turns and from $0.52 to $0.35, a reasonable measure of issue size. That's a 25–33% drop. Implementer cost fell 34% and cache reads 47%, so part of the saving is the issues and part is the change. A fair estimate puts the change itself at roughly 15–25% off implementer tokens, at the top of the plan's prediction. Comparing like-for-like issues would settle it.
- **The orchestration hop is nearly free.** A Haiku run costs a third of a cent, and dispatch plus relay add seconds against minutes of VM time. Overlapping the next implementation with a review on `--head` worked smoothly with two VMs.
- **Wall time is still VM-bound.** Each run is about 2.8 minutes; a typical issue needs one implementer run and one reviewer run, so about 6 of an issue's minutes are VM time. The model now spends about 1.5 minutes per issue in total across implementer and reviewer. Caching builds between runs, or reusing the implementer's passing run in review when the commit hasn't changed, is the next lever.
- **Quality held.** No bounces; the reviewers still found a real fan-out bug (#0103). Implementers repaired both failures from the reports alone, in seconds.
- **Not measured: the orchestrator.** Every relay passes through the orchestrating session, adding a few hundred tokens of report per run to its context. That is small next to what the implementers saved, but it isn't in the work-log totals.

### Recommendation

Keep the verify runner. Also:

- treat every failure report that needed more as a filter bug in `verify.sh`, as with the macro-expansion case;
- for a fair before/after, compare the next batch of ordinary feature issues against this baseline;
- try reusing the implementer's passing run in review, which would remove about a third of VM time per issue.

## UI runs

`scripts/verify.sh --ui` (#0200) adds the `ui-build` and `ui-tests` steps (XCUITests, only ever in the guest). They
make a run several minutes longer, so the runner starts UI runs in the background and waits for the completion
notification rather than holding a 600 s foreground call. The report is the same shape: a `UI` line on a pass; the
failing test, its assertion, a `screenshots:` folder and the xcresult path on a failure.

## Risks and open questions

- **Continuation is untested in practice.** The loop relies on `SendMessage` resuming a finished implementer with its context intact. If that proves unreliable, the fallback is to let the implementer call `scripts/verify.sh` directly. That keeps the short reports and drops only the Haiku hop.
- **Round-trip latency.** Each run now passes through the orchestrator twice. That costs seconds against minutes of VM time, but one quick `--build-only` check could cost relatively more than it used to.
- **Report gaps.** Hangs, timeouts and unusual crash formats may not match the filter. When a failed step has no recognised failure lines, the report falls back to the last 10 lines of its log, so something always comes back.
- **One working tree.** While a runner tests the working tree, the implementer must not edit files. It's paused waiting anyway. A second implementation still can't run at the same time.
