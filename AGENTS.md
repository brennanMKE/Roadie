# Agents

Guidance for AI agents working in this repo. The issue workflow (plan → implement → review, commits, work logs) is in [issues/Issues.md](issues/Issues.md), and verification in [docs/testing-in-vm.md](docs/testing-in-vm.md).

## Models

- **Do not use Fable unless the user asks for it.** Planning runs on Opus at medium effort, implementation on Opus at **low** effort, review on Opus at medium effort. Pass `model` and `effort` explicitly on every dispatch; the work log records both. After a bounce or a build-failure bail, the next implementation dispatch runs at medium.
