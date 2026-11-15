# Tasks

## 1. Permissions

- [x] 1.1 Add `Bash(elixir:*)`, `Bash(erl:*)` and `Bash(MIX_ENV=test mix:*)` to `Smelt.TaskRun`'s agent arguments, and update the "Agent permissions" test in `test/smelt/task_run_test.exs` to the new list (the proposal allows this one test change); verify with `mix test test/smelt/task_run_test.exs` and update the permissions line of the `Smelt.TaskRun` entry in `docs/architecture.md`
- [x] 1.2 Verify `mix precommit` and `openspec validate widen-agent-permissions --strict`, and update `docs/roadmap.md` (record the change, remove the item from "Next")

## Workflow follow-up

- Archive the change after review and merge (`openspec archive widen-agent-permissions`).
