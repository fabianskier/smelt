# Smelt

A personal, private software factory written in Elixir. It drives software development end to end — from a raw idea to merged code — and delegates the thinking, writing and reviewing of code to Claude Code.

The name: to *smelt* is to melt ore to extract pure metal. A raw idea goes in; tested code comes out.

## How it works

- **Smelt (Elixir/OTP) orchestrates**: states, queues, concurrency, gates, approvals and a live dashboard.
- **Claude Code executes**: discovery, specs, implementation and review, via headless `claude -p`.
- **OpenSpec defines the specs**: the format and lifecycle of each change (Spec-Driven Development).

See [`docs/architecture.md`](docs/architecture.md) for the full design.

## Requirements

- [mise](https://mise.jdx.dev): installs Erlang and Elixir from `mise.toml`, plus Node and the OpenSpec CLI (`@fission-ai/openspec`) from the global config.
- PostgreSQL 18 (Postgres.app in development).
- [Claude Code](https://claude.com/claude-code) CLI, logged in.

## Getting started

```sh
mise install       # Erlang, Elixir
mix setup          # deps, database, assets
mix phx.server     # or: iex -S mix phx.server
```

Then open [`localhost:4000`](http://localhost:4000).

Before committing, run `mix precommit` (compile with warnings as errors, format, test).

## Running a task

Smelt runs one task of an OpenSpec change in any local git project that has a `.smelt/checks.sh` (its tests and checks) and the change's `openspec/changes/<change>/tasks.md`:

```sh
mix smelt.task ~/code/viborita add-game-logic 1.1
```

It creates an isolated workspace (a git worktree) for the task, runs Claude Code on it, and runs the deterministic gate (protected tests, diff size, `openspec validate --strict`, the project's checks), resuming the agent once if the gate fails. You see the agent and the gate live; when the task passes, Smelt shows the diff and asks whether to merge it into the base branch (fast-forward only; it refuses if your checkout of that branch has uncommitted changes).

- `--merge` merges a workspace you kept, `--discard` removes it, `--base BRANCH` starts from another branch.
- Optional limits go in the project's `.smelt/gate.json`; see `docs/architecture.md`.
- Each task uses one or two Claude Code sessions of your plan's quota.

## Documentation

- [`docs/architecture.md`](docs/architecture.md): how Smelt works.
- [`docs/decisions.md`](docs/decisions.md): why it is built this way.
- [`docs/roadmap.md`](docs/roadmap.md): build path, current status and next steps.
- [`openspec/`](openspec/): living specs and changes in progress.
