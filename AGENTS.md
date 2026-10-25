# Agents

Guidance for AI agents working in this repo. The issue workflow (plan → implement → review, commits, work logs) is in [issues/Issues.md](issues/Issues.md), and verification in [docs/testing-in-vm.md](docs/testing-in-vm.md).

## Models

- **Do not use Fable unless the user asks for it.** Planning runs on Opus at medium effort, implementation on Opus at **low** effort, review on Opus at medium effort. The implementer never runs builds or tests itself: a Haiku runner at low effort runs `scripts/verify.sh` for it and returns only the short pass/fail report (`issues/Issues.md`, phase 2v). Pass `model` and `effort` explicitly on every dispatch; the work log records both. After a bounce or a build-failure bail, the next implementation dispatch runs at medium.

## Tests

- **Builds and tests run only in the Tart VM**, through the Haiku runner and `scripts/verify.sh`: never `xcodebuild`, `swift test` or XCUITest on the host (no ⌘U with the `Roadie UI Tests` scheme). Fast tests must pass before review; slow ones run once per milestone (`--head --full --ui --ui-skins all --coverage`).
- **Every bug fix lands with a regression test proven to fail first** (`verify.sh --expect-fail`); every user-facing change adds or updates a UI test. Rules: `issues/Issues.md`, phase 2.
- **`scripts/fetch-test-skins.sh` and `scripts/record-ma-fixtures.py` are host-only and read-only**; `.env` never enters the VM, a fixture or a log. Test hooks are Debug-only and never touch real user state.
- **The feature inventory** in `docs/design/test-automation.md` §5 is updated with the feature.

## GitHub

- **Use `gh` on the host, never in the VM.** The Tart guest has no `gh` and no GitHub credentials, and must not get them. Releases, tags, PRs, issues and `gh release view` checks run from this Mac. Scripts that run in the guest (the `scripts/verify.sh` steps, including `scripts/check-website.sh`) skip their GitHub checks there and note the skip; the host-side runs (`scripts/release.sh`, `scripts/check-website.sh` run directly) do them.
