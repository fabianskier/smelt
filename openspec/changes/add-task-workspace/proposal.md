# Proposal

## Why

Stage 2 runs a coding agent on one task end to end, and the agent needs somewhere to work. Running it in the user's own checkout would mix its edits with the user's uncommitted work, block running two tasks at once, and leave no clean record of where the task started, which the next change (the gate) needs to diff against.

## What Changes

- Add `Smelt.Workspace`: an isolated workspace per task, implemented as a git worktree on its own branch, created from a base branch (`main` by default) and stored outside the project's checkout.
- Operations to create a workspace, find it again, list a repository's workspaces, and remove one.
- Each workspace records its base branch and the exact base commit it started from.
- Removing a workspace keeps the branch when its work is not merged yet, unless removal is forced.
- Add `Smelt.Git`, a small wrapper around the `git` CLI used by the workspace.

## Capabilities

### New Capabilities
- `task-workspace`: create, find, list and remove an isolated working directory for one task of a change, without touching the user's checkout.

### Modified Capabilities
None.

## Impact

- New modules: `Smelt.Workspace`, `Smelt.Git`.
- New test helper to create throwaway git repositories in tests.
- Requires `git` (2.40 or later) on the machine running Smelt. No new Hex dependencies.
- No changes to `Smelt.Runner`: callers pass the workspace path as `cwd:`.
