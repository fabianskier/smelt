# Proposal

## Why

A task workspace is a fresh worktree with no dependencies or build, so the agent's first command fetches and compiles everything: minutes of waiting and output that lands in its context on every task. And nothing bounds what a single agent run may spend: a task that goes in circles costs as much as it likes before a human sees it.

## What Changes

- **Workspace setup**: when the base commit has a `.smelt/setup.sh`, Smelt runs it in the new workspace before the agent starts (for example `mix deps.get` and a compile). Its output never reaches the agent. A project without the script behaves as before. A failing or slow script does not stop the task: the failure is reported and the agent starts anyway.
- **Budget cap**: every agent attempt is started with a spending limit (`--max-budget-usd`), 5 USD by default and settable with `mix smelt.task ... --max-budget USD`. A probe (2026-11-16) confirmed the CLI ends such a run with an error result (`error_max_budget_usd`), which Smelt already treats as a failed agent, keeping the workspace.
- **Not in this change**: a turn limit (the CLI has no option for it), sharing dependencies between workspaces, and per-project budget settings.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `task-pipeline`: new requirements for the workspace setup and the budget cap.

## Impact

- New `Smelt.TaskRun.Setup`; `Smelt.TaskRun` (setup step with its events, `:max_budget_usd` option); `Mix.Tasks.Smelt.Task` (`--max-budget`, setup lines); `docs/architecture.md`, `docs/roadmap.md`.
- `.smelt/setup.sh` is read from the base commit, like the checks script, so a task cannot change it; it must write only ignored files (dependencies, build output), because anything else would be committed with the task.
- The cap applies to each attempt, so a task with a retry may spend up to twice the limit.
- Existing tests are not modified: without a setup script no new event is sent.
