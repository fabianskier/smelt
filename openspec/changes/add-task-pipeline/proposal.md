# Proposal

## Why

Smelt can now run an agent (`agent-runner`), give a task an isolated workspace (`task-workspace`) and check the result without AI (`task-gate`), but nothing connects them. Stage 2's goal is one task end to end, driven and approved from the terminal: until that exists, every task still has to be run, checked and merged by hand.

## What Changes

- Add `Smelt.TaskRun`, which runs one task of an OpenSpec change in a project repository:
  1. reads the task from the change's `tasks.md` at the base commit and creates the task's workspace;
  2. runs Claude Code in the workspace with a prompt for that task and limited permissions (read and edit files; run only `mix`, `git` without `push`, and the project's checks script);
  3. runs the gate; if it fails, resumes the same agent session once with the gate's findings and runs the gate again;
  4. reports the outcome, keeping the workspace for review.
- Approving a passed task merges it: remaining changes are committed, the task branch is rebased and gated again if the base branch moved, the base branch is fast-forwarded without touching uncommitted work in the user's checkout, and the workspace is removed. A task can also be discarded.
- Progress is broadcast as events over PubSub, so any interface can follow a task.
- Add `mix smelt.task <repo> <change> <task-id>`: shows the agent and the gate live, then asks for approval in the terminal; `--discard` drops a task's workspace.

## Capabilities

### New Capabilities
- `task-pipeline`: run one task of a change end to end (workspace, agent, gate, one retry), then merge it on approval or discard it, reporting progress as events.

### Modified Capabilities
None.

## Impact

- New modules: `Smelt.TaskRun`, `Smelt.TaskRun.TaskList`, `Smelt.TaskRun.Prompt`, `Mix.Tasks.Smelt.Task`.
- Uses `Smelt.Runner.ClaudeCode` (resuming a session with `--resume`), `Smelt.Workspace` and `Smelt.Gate` unchanged.
- Tests use a new fake agent script that edits and commits files in the workspace; `config/test.exs` gives `Smelt.Git` a fixed commit identity.
- Real runs use the Claude Pro quota: one task costs one or two agent sessions.
