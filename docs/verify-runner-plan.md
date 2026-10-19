# Verify runner: keeping build and test logs out of the implementer

Revision plan, 2026-10-19 (commit 9836a04). The rules live in [issues/Issues.md](../issues/Issues.md) (phase 2 and phase 2v). [issues-workflow.md](issues-workflow.md) covers the workflow as a whole. This page covers why the change was made, how it works, what it should save, and how we'll know.

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

`--expect testA,testB` makes the run fail unless each named test ran and passed. This replaces the rule "find your new test's name in the log", which was itself a reason to read logs.

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

## Risks and open questions

- **Continuation is untested in practice.** The loop relies on `SendMessage` resuming a finished implementer with its context intact. If that proves unreliable, the fallback is to let the implementer call `scripts/verify.sh` directly. That keeps the short reports and drops only the Haiku hop.
- **Round-trip latency.** Each run now passes through the orchestrator twice. That costs seconds against minutes of VM time, but one quick `--build-only` check could cost relatively more than it used to.
- **Report gaps.** Hangs, timeouts and unusual crash formats may not match the filter. When a failed step has no recognised failure lines, the report falls back to the last 10 lines of its log, so something always comes back.
- **One working tree.** While a runner tests the working tree, the implementer must not edit files. It's paused waiting anyway. A second implementation still can't run at the same time.
