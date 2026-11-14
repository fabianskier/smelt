# Tasks

## 1. Git wrapper and test support

- [x] 1.1 Implement `Smelt.Git.cmd/2` (runs `git -C <repo>`, merges stderr, base env `GIT_TERMINAL_PROMPT=0` and `LC_ALL=C` plus `config :smelt, Smelt.Git, env: …`, returns `{:ok, output}` or `{:error, {:git, args, status, output}}`), and set `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` for it in `config/test.exs`; verify with tests for a successful command, a failing command's error tuple, and that the global config is ignored (a `GIT_CONFIG_GLOBAL` value is not visible to `git config --get`)
- [x] 1.2 Add `test/support/git_repo.ex` with helpers to init a repo with an initial commit on `main`, add commits and branches, create modified and untracked files, and read a repo's current branch and status (all commits use `-c user.name/-c user.email/-c commit.gpgsign=false`); verify by using them in the 1.1 tests and with `mix test` passing

## 2. Identifiers, naming and metadata (pure)

- [ ] 2.1 Define the `%Smelt.Workspace{}` struct with typespecs, plus identifier validation and the naming functions (branch `smelt/<change>/<task-id>`, directory `<root>/<repo-name>-<hash8>/<change>/<task-id>`, metadata `<…>/<task-id>.json`, default root from `XDG_DATA_HOME` or `~/.local/share`); verify with unit tests for valid and invalid change names and task ids (`../escape`, `Add_X`, `1..2`, `main`, `2.`), deterministic paths for the same repo, and different hashes for two repos with the same name; document the naming, location and metadata of workspaces in a new `Smelt.Workspace` entry in `docs/architecture.md`

## 3. Create and fetch

- [ ] 3.1 Implement `Smelt.Workspace.create/4` (resolve the main checkout, verify the base, check for an existing branch or directory, `worktree add -b` at `base_sha`, write metadata, roll back on failure) and `fetch/4`, with tests grouped as `describe "Requirement: <name>"` / `test "Scenario: <name>"`; verify with tests for "Workspace is created from the base branch", "Another base branch is used", "Base branch does not exist", "Not a git repository", "Task already has a workspace", "Change name with a path separator", "Malformed task id", "Workspace is found again" and "Workspace does not exist"; document `create/4`, `fetch/4`, their options and error values in the `Smelt.Workspace` entry of `docs/architecture.md`
- [ ] 3.2 Add a test that `create` rolls back when the step after `worktree add` fails (for example, when the metadata directory is not writable): no directory, branch or metadata is left behind and the error is returned

## 4. List and remove

- [ ] 4.1 Implement `list/2` (parse `git worktree list --porcelain`, keep only `smelt/` branches with metadata); verify with the test for "Only managed workspaces are listed"
- [ ] 4.2 Implement `remove/4` (`worktree remove --force` or `worktree prune`, `merge-base --is-ancestor` against the base, `branch -D` when merged or forced, delete metadata, return `:removed`, `:branch_kept` or `:absent`); verify with tests for "Workspace without new commits is removed", "Unmerged branch is kept", "Forced removal deletes an unmerged branch", "Removing a missing workspace", and a removal after the workspace directory was deleted by hand; document `list/2` and `remove/4` (including `:force` and the return values) in the `Smelt.Workspace` entry of `docs/architecture.md`
- [ ] 4.3 Add the test for "Checkout with uncommitted work is preserved" (a checkout on a non-`main` branch with modified and untracked files, then a workspace is created and removed, and the branch and `git status --porcelain` output are unchanged)

## 5. Concurrency

- [ ] 5.1 Wrap `create` and `remove` in a per-repo `:global.trans` lock; verify with the test for "Concurrent creation for different tasks" (at least 8 `Task.async` creations in one repo, all `{:ok, _}`, with distinct paths and branches, and `list/2` returning all of them)

## 6. Integration

- [ ] 6.1 Run one manual check in `iex -S mix` against a scratch clone of a real repo: create a workspace, run `Smelt.Runner.ClaudeCode.run("Reply with exactly: ok", cwd: ws.path)`, then remove it; confirm the clone's checkout is unchanged. This is not part of the automated suite
- [ ] 6.2 Update the stage 2 status in `docs/roadmap.md`; verify `mix precommit` and `openspec validate add-task-workspace --strict` pass

## Workflow follow-up

- Archive the change after review and merge (`openspec archive add-task-workspace`).
- Then propose `add-deterministic-gate`.
