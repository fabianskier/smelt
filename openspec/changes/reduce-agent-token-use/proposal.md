# Proposal

## Why

Three `courier` tasks (2026-11-16) cost $1.33 to $1.80 each, in 26 to 33 turns, for diffs of 80 to 260 lines. The logs show avoidable turns: the agent ran the full checks, `mix precommit` and `openspec validate` two or three times each, although the gate runs the checks and the validation again; it retried `openspec validate` and `chmod` after they were denied; and a documentation-only task ran on the same model as a code task. The denied `chmod` also cost a script its executable bit: the agent set it in the index only, and the merge's leftover commit recorded the worktree's mode instead.

## What Changes

- **Permissions**: add `Bash(openspec validate:*)` and `Bash(chmod:*)` to the agent's allowed tools, so it can validate specs before the gate does and make a script executable in the worktree.
- **Prompt**: tell the agent to run `sh .smelt/checks.sh` once when the work is complete and again only after fixing a failure, not to run other full-suite commands in its place (the gate runs the checks and the OpenSpec validation), to run only the tests it touched while working, and not to retry or work around a denied command but to report it.
- **Model per task**: `mix smelt.task ... --model NAME` passes `--model NAME` to the agent on every attempt, so a documentation-only task can run on a cheaper model. Without the option nothing changes.
- **Existing test changed on purpose:** the "Agent permissions" test in `test/smelt/task_run_test.exs` asserts the exact allowed-tools list, so it is updated to the new list. No other existing test changes.
- **Not in this change**: choosing the model automatically, token or cost budgets per task, and changing how the merge commits leftover work.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `task-pipeline`: the "Limit the agent's permissions" requirement allows `openspec validate` and `chmod` as well; new requirements for the prompt's rules on checks and denied commands, and for the model option.

## Impact

- `Smelt.TaskRun` (agent arguments, a `:model` option), `Smelt.TaskRun.Prompt`, `Mix.Tasks.Smelt.Task` (`--model`), their tests, `docs/architecture.md` and `docs/roadmap.md`.
- Security is unchanged in practice: `mix` (already allowed) can run arbitrary code. The list prevents accidents; the workspace, the gate and human review are the real safeguards.
- The prompt's rule on checks is narrower than some projects' own instructions (for example "run `mix precommit` before finishing"); the gate still runs the project's checks, so nothing is verified less.
