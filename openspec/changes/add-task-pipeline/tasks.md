# Tasks

## 1. Task and prompt

- [x] 1.1 Implement `Smelt.TaskRun.TaskList.fetch(repo, base_sha, change, task_id)` (read `tasks.md` at the base commit, match `- [ ] <id> …` / `- [x] <id> …`, errors `:change_not_found`, `:task_not_found`, `:task_done`); verify with unit tests for an open task, a done task (`[x]` and `[ X ]`), a missing id, an id that is a prefix of another (`1.1` vs `1.10`) and a missing change
- [x] 1.2 Implement `Smelt.TaskRun.Prompt` (`task/2` and `retry/1` from a gate result); verify with tests that the task prompt contains the change, task id, description and `tasks.md` path, and that the retry prompt lists each failed rule's details and omits passed and skipped rules

## 2. Running a task

- [x] 2.1 Add `test/support/fake_agent`, and `GIT_AUTHOR_*`/`GIT_COMMITTER_*` for `Smelt.Git` in `config/test.exs`; implement `Smelt.TaskRun` with its struct, `new_id/0`, `subscribe/1`, `agent_run_id/2` and `run/4` (workspace, task, agent with the permission args, gate, one resumed retry, events); verify with tests named after the spec for "Task passes the gate", "Unknown task", "Task already done", "Prompt describes the task", "Agent permissions", "Fixed on retry", "Fails twice", "Agent fails" and "Progress events in order"
- [x] 2.2 Document `Smelt.TaskRun.run/4`, its outcome and events in a new `Smelt.TaskRun` entry in `docs/architecture.md`

## 3. Merging and discarding

- [x] 3.1 Implement `merge/2` (commit leftovers, rebase and gate again if the base moved, fast-forward in the checkout that has the base or with `update-ref`, refuse a dirty checkout, remove the workspace) and `discard/4`; verify with tests for "Approved task is merged", "Base branch not checked out", "Uncommitted work is committed on merge", "Base moved without conflicts", "Rebase conflict", "Checkout with uncommitted changes" and "Task discarded"; document `merge/2` and `discard/4` in the `Smelt.TaskRun` entry of `docs/architecture.md`

## 4. Terminal

- [x] 4.1 Implement `mix smelt.task REPO CHANGE TASK_ID [--base B] [--discard]` (live agent and gate output, diff stat, `[y/N]` approval, exit status); verify with `CaptureIO` tests for "Approve from the terminal" and "Decline keeps the workspace", plus `--discard`; document the command in `README.md`

## 5. Integration

- [x] 5.1 Run task 1.1 of `add-game-logic` in `~/code/viborita` for real with `mix smelt.task`, review the diff, and approve or decline; record what happened (outcome, attempts, cost, any problem) in the roadmap. This uses Claude Pro quota and is not part of the automated suite
- [x] 5.2 Update the stage 2 status in `docs/roadmap.md`; verify `mix precommit`, `openspec validate add-task-pipeline --strict`, and that every scenario in the spec has a test with the same name

## Workflow follow-up

- Archive the change after review and merge (`openspec archive add-task-pipeline`).
- Then decide stage 3: persistence and resuming, or dogfooding Smelt's own changes with `mix smelt.task`.
