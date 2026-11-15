# Proposal

## Why

Stage 2 needs to decide, without AI and without trusting the agent, whether a task's work in its workspace is acceptable before a human is asked to approve it. Today nothing checks the work: an agent could break the build, edit an existing test until it passes, rewrite the project's own checks, or change far more than one task should.

## What Changes

- Add `Smelt.Gate`: given a task workspace, it runs a fixed set of rules against the workspace's changes since its base commit and returns a pass or fail result with the outcome and details of each rule. It only reports; retrying or asking the agent to fix the work is the caller's decision.
- Rules in this first version:
  - **Protected files**: existing test files and the project's `.smelt/` configuration must not be modified or deleted. New tests are allowed.
  - **Diff size**: the change must stay under a maximum number of changed lines and files.
  - **OpenSpec validation**: `openspec validate --all --strict` must pass when the project uses OpenSpec.
  - **Project checks**: the project's `.smelt/checks.sh` must exit successfully within a timeout. It is skipped when a cheaper rule already failed.
- The project configures the gate in its own repository: `.smelt/checks.sh` (required) and `.smelt/gate.json` (optional limits and test paths). Both are always read from the workspace's base commit, so the agent cannot weaken its own gate.
- A checks script that exceeds its timeout is stopped together with every process it started.
- `Smelt.Git.cmd` accepts extra environment variables per call.
- Smelt gets its own `.smelt/checks.sh`, so it can gate its own tasks.

## Capabilities

### New Capabilities
- `task-gate`: decide deterministically whether a task workspace's changes pass the project's rules, from configuration taken at the task's base commit.

### Modified Capabilities
None.

## Impact

- New modules: `Smelt.Gate`, `Smelt.Gate.Result`, `Smelt.Gate.Config`, `Smelt.Gate.Changes`, `Smelt.Gate.Command`.
- `Smelt.Git.cmd/3` gains an `:env` option; existing calls are unchanged.
- New files in each gated project: `.smelt/checks.sh` and, optionally, `.smelt/gate.json`. Added to Smelt itself.
- Requires the OpenSpec CLI only for projects that have an `openspec/` directory. No new Hex dependencies.
