# Smelt

A software factory written in Elixir that takes one task of an [OpenSpec](https://github.com/Fission-AI/OpenSpec) change to merged code, and delegates the writing of that code to Claude Code.

The name: to *smelt* is to melt ore to extract pure metal. A task goes in; tested code comes out.

## What it is, and what it is not

Smelt is the mechanism around the agent: an isolated workspace, limited permissions, a deterministic gate, one retry, and a human who approves the merge. Claude Code does the thinking and the writing. OpenSpec defines the specs and the lifecycle of each change.

It is not a hosted service, a library, or a way to share a Claude subscription. Each user runs Smelt with their own Claude Code login.

## What works today

One task, end to end, from the command line:

1. a git worktree for the task, outside your checkout, with an optional `.smelt/setup.sh` run first;
2. headless Claude Code (`claude -p`) with limited permissions and a spending limit per attempt;
3. a deterministic gate: protected tests, diff size, `openspec validate --strict`, and the project's `.smelt/checks.sh`;
4. one resumed retry if the gate fails;
5. a human approval: you see the diff, then merge it (fast-forward only) or discard it;
6. a usage report for each run, appended to `usage.jsonl`, and detection of usage limits (a run stopped by one is reported as such, not as an agent failure).

## Parked or missing

- The LiveView dashboard (`/runs`) is parked on an unmerged branch; Smelt is used from the command line.
- Resuming runs after a crash.
- Parallel tasks and a merge queue.
- Writing proposals and specs (the agent only implements tasks of existing changes).
- Automatic review.

See [`docs/roadmap.md`](docs/roadmap.md) for status and next steps.

## Requirements

- [mise](https://mise.jdx.dev): installs Erlang and Elixir from `mise.toml`, plus Node and the OpenSpec CLI (`@fission-ai/openspec`) from the global config.
- PostgreSQL 18.
- [Claude Code](https://claude.com/claude-code) CLI, logged in with your own account. Each task uses one or two sessions of your plan's quota.

## Getting started

```sh
mise install       # Erlang, Elixir
mix setup          # deps, database, assets
```

## Running a task

Smelt runs one task of an OpenSpec change in any local git project that has a `.smelt/checks.sh` (its tests and checks) and the change's `openspec/changes/<change>/tasks.md`:

```sh
mix smelt.task ~/code/courier add-some-change 1.1
```

You see the agent and the gate live; when the task passes, Smelt shows the diff and asks whether to merge it into the base branch (it refuses if your checkout of that branch has uncommitted changes).

- `--merge` merges a workspace you kept, `--discard` removes it, `--base BRANCH` starts from another branch.
- Optional limits go in the project's `.smelt/gate.json`; see `docs/architecture.md`.
- Each agent attempt may spend at most 5 USD; change it with `--max-budget USD`. `--model NAME` picks the agent's model.

## What it built

[`courier`](https://github.com/fabianskier/courier) was built with Smelt. Smelt records usage since `courier`'s `add-release-demo-commands` change; the earlier changes ran before that and are not counted. Since then: 40 task runs over 13 OpenSpec changes; 37 passed the gate (2 agent failures, 1 stopped by a usage limit). They cost $39.48 in total, with a median of $0.87 per passed task, from $0.10 for a docs task on Sonnet to $4.56 for a frontend task that needed a retry.

## Documentation

- [`docs/architecture.md`](docs/architecture.md): how Smelt works.
- [`docs/decisions.md`](docs/decisions.md): why it is built this way.
- [`docs/roadmap.md`](docs/roadmap.md): build path, current status and next steps.
- [`openspec/`](openspec/): living specs and changes in progress.

## License

All rights reserved. The code is published for review only; see [`LICENSE`](LICENSE).
