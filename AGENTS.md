# Agents

Guidance for AI agents working in this repo. The issue workflow (plan → implement → review, commits, work logs) is in [issues/Issues.md](issues/Issues.md), and verification in [docs/testing-in-vm.md](docs/testing-in-vm.md).

## Models

- **Do not use Fable unless the user asks for it.** Planning runs on Opus at medium effort, implementation on Opus at **low** effort, review on Opus at medium effort. The implementer never runs builds or tests itself: a Haiku runner at low effort runs `scripts/verify.sh` for it and returns only the short pass/fail report (`issues/Issues.md`, phase 2v). Pass `model` and `effort` explicitly on every dispatch; the work log records both. After a bounce or a build-failure bail, the next implementation dispatch runs at medium.

## GitHub

- **Use `gh` on the host, never in the VM.** The Tart guest has no `gh` and no GitHub credentials, and must not get them. Releases, tags, PRs, issues and `gh release view` checks run from this Mac. Scripts that run in the guest (the `scripts/verify.sh` steps, including `scripts/check-website.sh`) skip their GitHub checks there and note the skip; the host-side runs (`scripts/release.sh`, `scripts/check-website.sh` run directly) do them.
