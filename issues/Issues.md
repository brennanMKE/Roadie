# Roadie

Roadie is a native macOS music player that renders classic Winamp 2.x `.wsz` skins and plays music from a Music Assistant server and local files. Issues are grouped into milestones from [docs/plan.md](../docs/plan.md): each milestone has an umbrella issue (Module `Milestone`) whose children are the tasks. Bugs found along the way belong here too.

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files (and `project.json`) are the source of truth — there is no generated artifact or index to keep in sync.

The `# Roadie` heading above should match the `name` field in `issues/project.json`. `project.json` is the canonical source for the project's identity (name + repo URL); this guide is the workflow companion.

## Folder layout

```
issues/
├── project.json       # canonical project name + repo URL
├── Issues.md          # this file
├── model-pricing.json # daily-refreshed model price cache (see "Token usage and cost tracking")
├── 0001.md            # one file per issue
├── 0001/              # optional sibling folder for screenshots, crash logs, etc.
│   └── screenshot.png
├── 0002.md
└── …
```

## Project config (`project.json`)

A small JSON file naming the project and its repo. Two required fields:

```json
{
  "name": "Roadie",
  "url": "https://github.com/user/repo"
}
```

- `name` — the project's human-readable name. Match the heading at the top of this file.
- `url` — the project's canonical web URL (HTTPS form, not SSH). Typically a GitHub URL; GitLab, Bitbucket, etc. work too.

When the repo moves or renames, edit `project.json` directly. Don't infer the project's name from the parent folder path — `project.json` is authoritative.

## Status values

| File value | Display name | Meaning |
|---|---|---|
| `open` | Open | Filed but not yet started |
| `in-progress` | In Progress | Actively being worked on |
| `resolved` | Resolved | Work is done; awaiting user confirmation |
| `closed` | Closed | User has confirmed the fix |
| `wontfix` | Won't Fix | Acknowledged but won't be addressed |

Use the **file value** (lowercase, hyphenated) in the issue's metadata table. The Mac app converts to the display name when rendering.

## Critical rule: never close without explicit confirmation

The most important rule of this workflow: an issue must **never** be marked `resolved`, `closed`, or `wontfix` based on inference. Only when the user has said so in plain language. Specifically, do not infer resolution from:

- a code change you (or a subagent) just made
- a commit message
- the filing of a related issue
- the user saying "thanks, that looks better"

Leave status at `open` (or `in-progress` if work has started) until the user confirms in words like "close this", "this is fixed", "mark resolved", or "won't fix". When in doubt, ask.

The deliberate exception: the **review subagent** (Opus, phase 3 of the standard workflow) may set `resolved` after independently re-verifying the fix (work-is-done-but-not-confirmed). The implementation subagent never sets `resolved` — it leaves the issue `in-progress` for review. No subagent ever sets `closed` — that's the user's call. This separation is the entire reason `resolved` and `closed` are different states.

## Git tracking

This project's choice on whether `issues/` is in git determines whether lifecycle events produce commits. Check on every operation:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null   # is this a git repo?
git check-ignore -q issues/                        # exit 0 = ignored, 1 = tracked
```

- **Not a git repo, or `issues/` is ignored**: edit files only; never commit. The Mac app still tracks changes from the working copy.
- **`issues/` is tracked**: each lifecycle event below produces its own commit.

When tracked:

| Event | What's committed | Commit message |
|---|---|---|
| Initial setup | `project.json` + `Issues.md` together | `Add issue tracker setup` (or bundle with the first `#NNNN` commit) |
| File a new issue | the new `NNNN.md` (and `project.json` / `Issues.md` if newly created) | `#NNNN <issue title>` |
| Planning adds `## Plan` | markdown (the `## Plan` section) | folded into `#NNNN <issue title>` if it lands first, else `#NNNN Plan` |
| Edit project config | `project.json` only | `Update project config` (or e.g. `Update project URL`) |
| Implementation — code commit | code changes only | `#NNNN <verb> <title>` |
| Review — resolution commit | markdown update (status + Closed + Commit + summary), made by the Opus reviewer | `#NNNN Resolve: <title>` |
| Review — bounce to open | markdown (status back to `open` + `## Review notes`) | `#NNNN Review: <reason>` |
| Bail with notes | markdown only | `#NNNN Notes: <brief>` |
| Work-log row appended | markdown only | `#NNNN Work log: <model>, <total tokens>, $<cost>` |
| Daily pricing refresh | `model-pricing.json` only | `Update model pricing` |
| User-confirmed close | markdown only | `#NNNN Close` |
| Won't fix | markdown only | `#NNNN Won't fix` |

**Working-copy-only changes (no commit):**

- Setting status to `in-progress` at the start of work — transient; the resolve commits supersede it. Committing every status flip would create noise.

**Why two commits to resolve, not one:** the **Commit** metadata row records the hash of the code-fix commit, and that hash isn't known until *after* the code commit lands. Splitting resolution into a code commit and a resolution commit keeps each commit single-purpose ("fix the code", "document the fix") and lets the resolution commit reference the hash cleanly.

## Issue file format

Each issue is `NNNN.md` (4-digit zero-padded) with this structure:

```markdown
# NNNN — Title

| | |
|---|---|
| **Status** | open |
| **Module** | <module name(s)> |
| **Platform** | iOS · macOS · iPadOS · All |
| **First seen** | YYYY-MM-DD |

## Description

What is wrong. Lead with the punchline — the first paragraph shows in the Mac app summary.

## Steps to reproduce

1. …
2. …

## Expected behavior

What should happen.

## Actual behavior

What actually happens.

## Attachments

![caption](NNNN/screenshot.png)

## Notes

Any additional context, guesses at root cause, related code locations.
```

### Format details that matter

- **Title separator** is an em-dash (U+2014, `—`), not a hyphen.
- **Metadata field rows** must keep the field name in `**bold**` exactly.
- **Dates** are `YYYY-MM-DD`.
- **Module** can list multiple modules separated by ` / ` (e.g. `BlueskyFeed / BlueskyDataStore`).
- **Platform** is `iOS`, `macOS`, `iPadOS`, `All`, or any other string. `All` is treated as matching every platform filter.
- When status moves to `resolved` or `closed`, add a `**Closed**` row with today's date. When the move to `resolved` is the result of a fix commit, also add a `**Commit**` row with the short hash (`git rev-parse --short HEAD`).
- Steps / Expected / Actual / Attachments / Notes are conventional but not all required — for design-refinement or feature-gap issues, Description alone is fine.

## Filing a new issue

1. Confirm `issues/project.json` exists. If missing, create it (see schema above) before filing the first issue — `name` should match this guide's heading; `url` is the project's canonical web URL (HTTPS, not SSH).
2. Find the highest existing `NNNN.md` and increment. Start at `0001` if the folder is empty. Skip past reserved high numbers (e.g. `8888`, `9999` for test issues).
3. Create `issues/NNNN.md` from the template.
4. Set status to `open`.
5. Use today's date for First seen.
6. Phrase the title as a single declarative sentence describing the bug, not a question or a fix description.
7. **Plan it (phase 1).** Dispatch a fresh subagent on **Opus** (not Fable unless the user asks; see `AGENTS.md`) to read this guide, `CLAUDE.md`, the new issue, and the relevant code, then write a `## Plan` section into `issues/NNNN.md` (after `## Description`). It writes no code and leaves status at `open`. This gives whoever picks the issue up a running start. Record the planner's usage in `## Work log`. Skip if the user is jotting a quick note and doesn't want planning yet.
8. **Put it in a milestone.** Every open issue belongs to one. Add `- Parent: [#M](M.md)` under `## Relation` and a row to the umbrella issue's `## Children` table. A cleanup or follow-up issue found while working a milestone goes under that milestone; work that fits none gets a new umbrella (Module `Milestone`).
9. **If `issues/` is tracked by git**, commit the new file with message `#NNNN <issue title>` so the issue enters git history with its `open` status — the `## Plan` rides along if it's landed, else commit it separately as `#NNNN Plan`. If ignored, skip.

## Updating an issue

Edit the file in place. The Mac app picks up changes automatically — no follow-up command. Touch only the rows or sections that changed; don't reformat the rest.

When status moves to `resolved` or `closed`, add a `**Closed**` row with the date. When the move to `resolved` was driven by a fix commit, also add a `**Commit**` row with the short hash. For any move toward `resolved`, `closed`, or `wontfix`, the "Critical rule" near the top of this file applies — those transitions require explicit user confirmation, not inference.

## The standard workflow (plan → implement → review)

Issues move from filed to resolved through a **three-phase pipeline**. Each phase runs in a **fresh subagent** dispatched by the orchestrator, on the model that fits the work:

| Phase | When | Model | The subagent does | Status after |
|---|---|---|---|---|
| **1. Planning** | at issue creation (see "Filing a new issue") | **Opus · medium** | reads conventions + issue, writes `## Plan`; no code | `open` |
| **2. Implementation** | when the issue is worked | **Opus · low** (medium after a bounce or bail) | follows the plan and edits code; hands each build/test to a runner and fixes from its report; after a pass, code commit and resolution drafts | `in-progress` |
| **2v. Verification runner** | each time the implementer asks for a run | **Haiku · low** | runs `scripts/verify.sh` with the implementer's arguments and returns its short report verbatim; never reads logs or edits | — |
| **3. Review** | after implementation returns | **Opus · medium** | independently re-verifies the diff, then approves or bounces | `resolved` or `open` |

Fresh context per phase is deliberate: each subagent reloads this guide and `CLAUDE.md` cleanly, so edits to those files take effect on the next dispatch. Each phase runs *only* in a subagent, never in the orchestrator's own context, to keep its large context isolated. Use Fable only when the user asks for it (`AGENTS.md`).

### Orchestrator: pick and dispatch

1. **Refresh the pricing cache if stale.** If `issues/model-pricing.json` is missing or its `fetched` date isn't today, fetch current model prices and rewrite it (once per day). See "Token usage and cost tracking" below.
2. **Work milestone by milestone.** Finish the milestone in progress before starting another. Within it, pick the lowest-numbered child whose status is `open` and that carries a `## Plan` from phase 1 (plan it first if not); respect `Blocked by` lines. Skip issues that need what agents can't do (the user's Mac, a live server, hardware, a decision): add or update their `## Notes` and leave them open. Keep the umbrella's `## Children` table in step with each status change.
3. **Dispatch a fresh Opus subagent at low effort** (phase 2) with the issue id and instructions to follow the implementation steps below. If the issue was bounced or bailed before, dispatch at medium instead. Pass `model` and `effort` explicitly on every dispatch (all three phases).
4. **Run the implement ⇄ verify loop.** The implementer returns either a `VERIFY:` request (a `scripts/verify.sh …` command line) or `DONE`/a bail.
   - On `VERIFY:`, dispatch a fresh **Haiku runner at low effort** (phase 2v) with that exact command. It can run in the background while you do other orchestration.
   - When the runner returns, **continue the same implementer** (`SendMessage` to its agent id, so its context is intact) with the runner's report pasted verbatim: `VERIFY PASS …` or `VERIFY FAIL …`. Don't add the logs, and don't summarise the report.
   - Repeat until the implementer returns `DONE` (it commits after a pass) or bails. After the third failed run on the same issue, tell it to bail instead of trying again.
   - Record each runner's usage as a `verify` row. The implementer gets one `implement` row covering all its turns when it finishes.
5. **When the implementer returns `DONE`,** record its usage and dispatch a fresh **Opus reviewer at medium effort** (phase 3) for the same issue. Record the reviewer's usage when it returns.
6. If the reviewer bounced the issue back to `open`, re-dispatch phase 2. Otherwise move on to the next open issue (or stop if only one was requested).
7. If the issue just resolved was a milestone's last open child, run the milestone-end full tier (see "Build / verify command").
8. **Overlap where it’s safe.** Two VM runs may run at once (two guests; concurrent runs leave each other alone since #0095). A review or milestone run that tests `--head` doesn't see the working tree, so the next issue's implementation can start while it runs. Two implementations, or an implementation and a review that tests the working tree, must not overlap: they share one working tree.

Usage is recorded per phase — locate the subagent's transcript, sum token counts (deduped by `requestId`), note the model, compute cost, and append a `## Work log` row. Bails and bounces get a row too. If the user names a specific issue ("fix 0046"), dispatch phase 2 to that id directly.

### Phase 2 — Implementation subagent (Opus, low effort): claim → fix ⇄ verify → commit

A subagent starts with fresh context, so its first job is loading the project's conventions.

1. **Orient in the project.** Read, every time, in order:
   - **`issues/Issues.md`** (this file) — status vocabulary, module conventions, build/verify command, commit conventions, project rules. **Authoritative for issue-tracking workflow.**
   - **`CLAUDE.md`** at the repo root, if it exists — project-wide guidance, code conventions, restricted areas, build/test commands. **Binding.**
   - **`issues/NNNN.md`** — the issue in full, **including its `## Plan`** and any attachments in `issues/NNNN/`.

   If the two guides disagree, prefer `CLAUDE.md` for code/repo conventions and this file for issue-tracking specifics.

2. **Set status to `in-progress`** in the markdown — working copy only, no commit. The Mac app picks it up immediately.
3. **Make the code changes** required to fix the bug, following the `## Plan`. If you deviate, note why in `## Fix` so the reviewer understands.
4. **Hand every build and test run to the runner; never run them yourself.** Mandatory; cannot be shortcutted. You don't run `scripts/run-tests-vm.sh`, `scripts/verify.sh`, `swift` or `xcodebuild`, and you don't read `build/vm-tests/` logs. Full build and test output is thousands of lines and would fill your context. A Haiku runner (phase 2v) runs the build and tests, and only the short report from `scripts/verify.sh` comes back to you.

   - **Ask for a run** by ending your turn with exactly one line:
     `VERIFY: scripts/verify.sh [--build-only] [--full] [--launch] [--expect testA,testB]`
     Use the tier the plan names (`--full` when "Which tier" says so). List every test you added or changed in `--expect`, by function name: the run then fails unless each of them ran and passed. For a bug fix, the line may instead carry `--expect-fail testA` (run before the fix: passes only if that test fails and nothing else does). The orchestrator has the runner execute the command and continues you with its report. Don't edit files while a run is pending.
   - **Compile first if unsure.** `--build-only` checks only that everything compiles. A compile error shows up in about 1.6 minutes, but a build-only pass is never verification. The run that counts is a complete fast or full run. Skip `--build-only` when you're confident: a complete run reports compile errors too.
   - **On `VERIFY FAIL`**, fix from the report and ask again. The report holds:
     - the failing steps;
     - compiler errors as `file:line:col`;
     - each failing test's `✘` lines, with the `↳` lines showing the values;
     - crashes, and expected tests that didn't pass.

     That is the whole failure, so don't go looking for the logs. If the report really isn't enough, which should be rare, say what's missing in `## Notes` and bail. After three failed runs on the same issue, bail.
   - **Exit 3 (`INFRA`)** means the VM itself failed, not the code; `verify.sh` already retries it once. If the report still says INFRA, ask for the same run again.
   - **A failure in code you didn't touch.** If the only failure is a test your change can't affect, ask for the same run once more and record both. If it fails again, or fails on other issues too, file a flaky-test issue under the tooling milestone (M11, #0087) and say so in `## Notes`; don't fix it inside this issue.
   - **Compilation is not verification.** "It builds" doesn't count. A complete run must pass: the `VERIFY PASS` line, a test total above zero, and, when you added tests, `EXPECT  all N expected test(s) passed`. A pass with no `EXPECT` line after adding tests is not verification; ask again with `--expect`.
   - **If verification can't run** (it needs the user's Mac, credentials or hardware), you haven't verified the fix. Bail per "When the subagent can't finish", naming the step that couldn't run.
   - **If the build was already failing before you started**, note it and bail; don't fix unrelated breakage.
   - **Quote the evidence.** In `## Verification`, quote the passing report's lines verbatim:
     - `VERIFY PASS` with its run id, step count and test total;
     - the `TIER` and `AUDIO` lines;
     - the `EXPECT` line.

     The run's `summary.txt` has the full step list if a human wants it. Never ask for a run again just to recapture output.

5. **Make the code commit.** Stage *only the code changes* (not the issue markdown yet). The message starts with `#NNNN` and a short, declarative title — the verb that fits (`Fix`, `Add`, `Refactor`, `Update`, `Remove`, …); not every issue is a bug fix. Blank line, then a paragraph of detail. Example:

   ```
   #0046 Add navigation from avatar tap to profile

   The avatar tap on PostCardView was not wired to any NavigationLink.
   Threaded the author DID through the cell and connected onTapGesture
   to push ProfileView.
   ```

6. **Capture the commit hash** with `git rev-parse --short HEAD`.
7. **Draft the resolution sections in the markdown — but do NOT set `resolved`.** That's the reviewer's transition.

   - Leave **Status** at `in-progress`; add a `**Commit**` row with the short hash from step 6.
   - Add, all *after* `## Description`:
     - **`## Root cause`** — what was actually wrong.
     - **`## Fix`** — the approach taken; call out any divergence from the plan.
     - **`## Verification`** — the exact command(s) you ran and what you observed (e.g. "`xcodebuild test -scheme MyAppUITests` — 14 tests passed including the 3 new in `ReplyButtonUITests`"). Name new tests and confirm they ran.
     - **`## Files changed`** — one bullet per file, with a short note on what changed.
     - **`## Gotchas`** *(optional)* — surprises, dead ends, non-obvious behavior. Skip if nothing's notable; be specific when present.

8. **Do not commit the markdown draft.** Return to the orchestrator with `DONE: <one-line summary>`. The reviewer makes the single resolution commit in phase 3.

### Phase 2v — Verification runner (Haiku, low effort)

A mechanical step, so it runs on the cheapest model. The orchestrator gives it one command line from the implementer's `VERIFY:` request.

1. Run exactly that command from the repo root with the Bash tool. Use a timeout of 600000 ms; a `--stress` or `--corpus` run that may take longer goes in the background, and you wait for its completion notification.
2. Return the command's complete stdout **verbatim**, followed by `exit <code>`. It is short by design (5–10 lines on a pass, at most about 60 on a failure).
3. Never read the logs under `build/vm-tests/`, run any other command, edit files, re-run on failure (`verify.sh` already retries INFRA once), or interpret the result. Diagnosis is the implementer's job.

### Phase 3 — Review subagent (Opus): verify → resolve or bounce

An independent reviewer is the gate between "code landed" and "issue resolved". It owns the `resolved` transition; the implementation subagent never sets it.

1. **Orient** the same way (this file, `CLAUDE.md`, `issues/NNNN.md` including the `## Plan` and the drafted resolution sections).
2. **Inspect the code commit** — read its diff (`git show <hash>`). Does it actually address the reported bug? Right scope? Any correctness, security, or regression risk?
3. **Re-run the verification yourself**; don't trust the drafted `## Verification`. Run `scripts/verify.sh --head` with the same tier and `--expect` list as the implementer's passing run. Use the quiet wrapper, not `run-tests-vm.sh`, so the full logs stay out of your context. `--head` tests the committed code, not whatever else is in the working tree (the orchestrator may have the next issue's implementation running). Hold it to the same standard as phase 2, step 4, and quote the same lines. This independent run is the core of the review. If it fails and the report isn't enough to judge, you may read the named step's log under the results directory, since a review needs the diagnosis.
4. **Decide:**
   - **Approve** (fix is correct, verification passed): change **Status** to `resolved`; add a `**Closed**` row with today's date; ensure the `**Commit**` row is present; add a top-of-resolution `## Resolution notes` blockquote (`> 🟢 Resolved YYYY-MM-DD — <one sentence>.`). **If `issues/` is tracked**, make the resolution commit — stage `issues/NNNN.md`, message `#NNNN Resolve: <title>`, body noting the code commit hash. If ignored, skip; the markdown is the record.
   - **Bounce** (verification failed, fix wrong, scope off): revert **Status** to `open`; add a `## Review notes` section stating exactly what failed and what the next implementation pass must fix. Leave the code commit in place unless you say otherwise in the notes. **If tracked**, commit the markdown with `#NNNN Review: <reason>`. Return to the orchestrator, which re-dispatches phase 2.

Status flow: `open` (with `## Plan`) → `in-progress` → review → `resolved`, or bounced back to `open`. **Never set `closed`** — the user does that after verifying the fix.

### Build / verify command for this project

**Verify in the Tart VM, never on the host.** See [docs/testing-in-vm.md](../docs/testing-in-vm.md).

- Verification command: `scripts/run-tests-vm.sh`, which runs the **fast tier** (add `--launch` to also start the app in the guest). It exports the working tree, generates the project, and runs in a fresh, muted guest with no audio path to the host: `swift test` for SkinKit, `swift test` for PlayerKit (AudioCore, the backends, Music Assistant and the browser), the Debug app build (`build-for-testing`), the app's hosted unit tests (step `app-unit-tests`, `RoadieTests`), and a check of the built app's Info.plist. The fast tier skips the slow tests: the three 100k SkinLibrary tests (`SkinIndexScaleTests`, `SkinSearchBudgetTests`) (gate `ROADIE_SLOW_TESTS=1`) and the real-time AudioCore tests (gate `AUDIOCORE_REALTIME=1`). `scripts/run-tests-vm.sh --full` is the **full tier**: everything above plus those slow tests. It passes only if every step passes and the host logged no audio. Logs are in `build/vm-tests/<run-id>/`, and the summary, with the exit code, is in `summary.txt` there; quote its lines in `## Verification`. Quote the `TIER` line too. The run starts with a build stage (`swift build --build-tests` for each package, then the app's `xcodebuild`), and the test steps reuse it (`swift test --skip-build`). If anything fails to compile, that build step shows `FAIL`, the steps that depend on it show `SKIP` (the other package still builds, so one run reports errors from both), and the compiler errors are printed under `ERRORS`. Exit codes: 0 passed, 1 a step or the audio check failed, 2 bad arguments, 3 infrastructure (`INFRA`: the guest was lost or didn't boot; rerun). A run with `SKIP` lines is a failed run. `scripts/run-tests-vm.sh --build-only` stops after the build stage; use it as a compile check before a complete run (phase 2, step 4), never as verification.
- **Agents call `scripts/verify.sh`, not `run-tests-vm.sh`.** `verify.sh` takes the same options plus `--expect NAMES`. It sends the run's full output to `build/vm-tests/<run-id>/run.out` and prints only a short report:
  - **On a pass:** `==> VERIFY  PASS (exit 0) <run-id>: N steps passed, T tests in R test runs`, then the `TIER`/`AUDIO` lines and the `EXPECT` result.
  - **On a failure:** `==> VERIFY  FAIL (exit N)`, then the `FAIL`/`BUILD`/`ERRORS`/`INFRA`/`AUDIO` lines from `summary.txt` and, from each failed test step's log, the `✘` lines, the `↳` lines with their values, crashes and fatal errors. It stops at 60 lines and keeps the full report in `failure.txt`.

  The exit code is the run's. A missing or failed `--expect` test makes it 1. Exit 3 is retried once automatically. People can still call `run-tests-vm.sh` directly to watch a run.
- **Which tier.** Phases 2 and 3 run the fast tier. They also run the full tier (`--full`), and quote both summaries, when the change touches code a slow test guards. That means anything under `Packages/SkinKit/Sources/SkinLibrary/` (indexer, store, SQLite/FTS, folder scanner), or anything under `Packages/PlayerKit/Sources/AudioCore/` that affects real-time playback: `Player`, `GaplessScheduler`, `AudioGraph`, `Progressive/`, `Output/`, `NowPlaying/`. When unsure, run `--full`. The plan should say which tier the issue needs.
- **Milestone end.** When the review of a milestone's last open child resolves it (every issue with `Parent: #M` is `resolved`, `closed` or `wontfix`), the orchestrator runs `scripts/verify.sh --full --head` once (directly, or through a Haiku runner) and records the run id and the `PASS`/`FAIL`/`TIER` lines in the umbrella issue's `## Notes` (commit `#M Notes: full tier <passed|failed>`). If anything fails, file a new cleanup issue with `Parent: #M` for each distinct failure, through the normal filing and planning steps. Never reopen a resolved child for it. The milestone is not done until a full-tier run passes.
- Don't run `swift test`, `xcodebuild` or the app on the host to verify a change. `xcodegen generate` on the host is fine (the script runs it into the export itself).
- **Tests must be silent.** Nothing may play through the host's speakers. Most of the suite renders offline (manual rendering mode, see `renderSilently` in `TestSupport.swift`); real-time tests are opt-in with `AUDIOCORE_REALTIME=1`, mute the main mixer, and are only turned on in the VM's full tier (`--full`). Scratch harnesses and review experiments follow the same rule: run them in a VM clone, or render offline. The script checks the host with `/usr/bin/log show --predicate 'process == "coreaudiod" AND eventMessage CONTAINS "Starting IO"'` (in zsh a bare `log` is a shell builtin).
- Skin report: `swift run --package-path Packages/SkinKit skintool Skins/`
- Opt-in integration tests: set `SKIN_CORPUS_DIR`, or `MA_URL` + `MA_TOKEN`. Never write the token to disk or logs.

### When the subagent can't finish

If the bug is unreproducible, out of scope, or the build won't pass after reasonable effort:

1. **Discard or stash any partial code changes** so the bail doesn't accidentally include half-done work.
2. **Revert status to `open`** in the issue markdown so the issue goes back into the queue.
3. **Add a `## Notes` section** describing what was tried, why work stopped, and what you'd try next. Be specific.
4. **If `issues/` is tracked by git**, commit the markdown change with message `#NNNN Notes: <one-line bail summary>`. If ignored, skip.
5. Return with a one-line summary of why work stalled.

Never use `wontfix` or `closed` to escape a stuck issue.

## Token usage and cost tracking

Every subagent dispatch gets a usage record on the issue it worked: which model did the work, exactly how many tokens it consumed, and an estimated cost. The **orchestrator** records this after the subagent returns — a subagent can't measure its own totals. Under the three-phase workflow each issue accumulates a row per phase — **planning (Opus, medium), recorded at filing time; implementation (Opus, low, or medium after a bounce); one verify row per runner (Haiku, low); review (Opus, medium)** — plus a row for every bounce or bail. Each row also records the effort level, wall-clock duration, and the time spent in VM test runs.

### Pricing cache (`issues/model-pricing.json`)

Anthropic publishes prices on the docs site (no API endpoint). Fetch once per day, cache to:

```json
{
  "fetched": "YYYY-MM-DD",
  "source": "https://docs.claude.com/en/docs/about-claude/pricing",
  "currency": "USD per MTok",
  "models": {
    "claude-fable-5-1": { "input": 10.00, "output": 50.00, "cache_write_5m": 12.50, "cache_write_1h": 20.00, "cache_read": 0.25 },
    "claude-opus-5-5": { "input": 4.00, "output": 20.00, "cache_write_5m": 5.00, "cache_write_1h": 8.00, "cache_read": 0.20 },
    "claude-sonnet-5-5": { "input": 2.00, "output": 10.00, "cache_write_5m": 2.50, "cache_write_1h": 4.00, "cache_read": 0.10 }
  }
}
```

If `fetched` is today, use as-is. If the fetch fails, use the stale cache and note the staleness next to the cost; with no cache at all, record tokens and model with `—` for cost. Never trust example numbers over a fresh fetch.

### Getting exact token counts

Claude Code writes each subagent's transcript to `~/.claude/projects/<project-slug>/<session-id>/subagents/agent-<id>.jsonl`, where `<project-slug>` is the working directory with `/`, `.`, and `_` replaced by `-`. Assistant lines carry `message.usage` (exact `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`) and `message.model`.

**Dedupe by `requestId`** — one API response can span several JSONL lines repeating the same usage object; summing every line over-counts. Find the newest agent file mentioning the issue id, keep one usage entry per `requestId`, and sum.

```
cost = (input × input_rate + output × output_rate
      + cache_read × cache_read_rate + cache_write × cache_write_5m_rate) / 1,000,000
```

If no transcript is available (different harness), record whatever total the harness reported, or `—`. Never fabricate counts.

**Output tokens are not in the transcript.** `message.usage` is the stream-start snapshot: `input_tokens` and `output_tokens` are near zero on every line, while the cache fields are exact. Estimate output as the character count of all assistant content (text, thinking, tool_use input) divided by 4, and mark it `~`. **Effort** is the `effort` field on assistant lines. **Wall** is the span between the first and last `timestamp`. **VM** is the count and total duration of tool_use → tool_result pairs whose command runs `scripts/run-tests-vm.sh` or `scripts/verify.sh`. An implementer that is continued after each runner report has idle gaps while it waits; **Wall** leaves those out (the time between its turn ending and the next continuation). `scripts/worklog.py <transcript.jsonl>` computes all of these and prints a ready work-log row.

### The `## Work log` section

One row per work session, conventionally the last section of the issue file (always after `## Description`). The optional **Phase** column (`plan` / `implement` / `review`) makes the three-phase breakdown legible:

```markdown
## Work log

| Date | Phase | Model | Effort | Wall | VM | Turns | Output | Cache read | Cache write | Cost | Outcome |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-20 | plan | claude-opus-5-5 | medium | 9m | — | 20 | ~29,400 | 2,088,496 | 157,531 | $2.38 | planned |
| 2026-10-20 | verify | claude-haiku-5-5 | low | 3m | 1 (2.9m) | 3 | ~300 | 45,000 | 12,000 | $0.00 | failed |
| 2026-10-20 | verify | claude-haiku-5-5 | low | 3m | 1 (2.7m) | 3 | ~250 | 45,000 | 12,000 | $0.00 | passed |
| 2026-10-20 | implement | claude-opus-5-5 | low | 18m | — | 41 | ~46,000 | 4,100,000 | 190,000 | $2.70 | reviewed |
| 2026-10-20 | review | claude-opus-5-5 | medium | 7m | 1 (3.0m) | 27 | ~4,800 | 2,431,182 | 117,810 | $1.19 | resolved |

**Total: $6.27**
```

Update the `**Total**` line whenever a row is appended. Outcome is one of `planned`, `reviewed` (implementation handed to review), `passed`/`failed` (a verify run), `resolved`, `bounced`, `bailed`, `stopped`. A verify row goes in when its runner returns; the implementer's single row goes in when it returns `DONE` or bails, and its VM column is `—` because the runners did the runs. Older tables keep their columns; when an older issue gets a new row, extend its header to these columns and pad earlier rows with `—`, the one exception to "don't reformat". The `plan` row lands at filing time; the `implement` and `review` rows land as each phase returns. Bails and bounces get a row too. Don't reformat existing rows.

## Attachments

Screenshots, crash logs, console output, sample data, etc. live in a sibling folder `issues/NNNN/`. Reference them with paths *relative to the issue's `.md` file* — that means the folder prefix `NNNN/` is part of the link target. The bytes that ship are `1335/screenshot.png`, not `screenshot.png` and not `issues/1335/screenshot.png`.

```
issues/1335.md           ← the markdown that contains the link
issues/1335/screenshot.png   ← the file being linked

# inside 1335.md the link reads:
![caption](1335/screenshot.png)
```

Concrete example with both image and video attachments:

```markdown
## Attachments

![Reply button does nothing when tapped](1335/screenshot.png)
![Crash log](1335/crash.log)
[![Sidebar resize jitter](1335/sidebar-resize-jitter.poster.png)](1335/sidebar-resize-jitter.mov)
```

### Videos (`.mov`, `.mp4`, etc.)

Videos can't be embedded as `![…](…)` — markdown renderers treat that as an `<img>` and a `.mov` won't load. Instead, generate a poster frame with `qlmanage` and emit an image-inside-a-link (shown in the example above). Quick recipe — copy the video into `issues/NNNN/` first, then:

```bash
qlmanage -t -s 1280 -o issues/NNNN issues/NNNN/<basename>.<ext>
mv issues/NNNN/<basename>.<ext>.png issues/NNNN/<basename>.poster.png
```

`qlmanage` ships with macOS — no install. It reliably produces posters for AVFoundation-supported formats: `.mov`, `.mp4`, `.m4v`, `.qt`. For `.avi` it usually works; for `.mkv` and `.webm` it generally fails on stock macOS unless a third-party Quick Look generator is installed. If the rename step doesn't produce the `.poster.png`, fall back to the plain `![alt](NNNN/file.mov)` form with a `<!-- poster generation failed -->` HTML comment in the Attachments section. Don't apply the link wrapper to plain images, and don't generate posters for animated GIFs.

### macOS screenshot / screen recording filename gotcha

macOS Screenshot and Screen Recording filenames both use a **narrow no-break space** (U+202F) before AM/PM, visually identical to a regular space. A literal `cp` of the quoted filename will fail with "No such file or directory". Use a glob to skip past it:

```bash
mkdir -p issues/NNNN
cp ~/Desktop/Screenshot\ YYYY-MM-DD\ at\ H.MM.SS*PM.png issues/NNNN/screenshot.png
cp ~/Desktop/Screen\ Recording\ YYYY-MM-DD\ at\ H.MM.SS*PM.mov issues/NNNN/recording.mov
```

The `*` matches the U+202F. Substitute the actual timestamp; if you don't know which file the user means, list `~/Desktop/Screenshot*` or `~/Desktop/Screen\ Recording*` by mtime and pick the most recent.

## Module conventions for this project

- `SkinKit`: skin parsing, sprites, `skintool` (`Packages/SkinKit`)
- `AudioCore`: AVAudioEngine playback, EQ, analyzer, queue (`Packages/PlayerKit`)
- `MusicAssistantKit`: Music Assistant WebSocket client and models (`Packages/PlayerKit`)
- `App`: SwiftUI/AppKit app (`App/`)
- `QuickLook`: Quick Look thumbnail and preview extensions for `.wsz` (new targets in `project.yml`)
- `Milestone`: umbrella issues only
