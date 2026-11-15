# Tasks

## 1. Git environment per call

- [x] 1.1 Add `Smelt.Git.cmd/3` with an `:env` option (variables added on top of the base and configured environment; `cmd/2` unchanged); verify with a test that a per-call variable reaches git (for example `GIT_INDEX_FILE` pointing at a missing file makes `git ls-files` list nothing) and that the existing `Smelt.Git` tests pass unchanged

## 2. Configuration

- [x] 2.1 Implement `Smelt.Gate.Config.load(repo, base_sha)` (read `.smelt/gate.json` at the base commit with `git cat-file -e` / `git show`, apply defaults, strict validation of keys, types and positive numbers, `{:error, {:invalid_config, message}}`), and add a `Smelt.GitRepo` helper to write `.smelt/` files; verify with tests for "Defaults without a configuration file", "Settings from the base commit" (unit level) and "Invalid configuration" (bad JSON, wrong type, unknown key, non-positive number); document `.smelt/gate.json` in a new `Smelt.Gate` entry in `docs/architecture.md`

## 3. Changes and cheap rules

- [x] 3.1 Implement `Smelt.Gate.Changes.measure(ws)` with a temporary index (`read-tree HEAD`, `add --all`, `diff --cached --no-renames -z --name-status / --numstat <base_sha>`), returning each changed path with its change type and line counts; verify with tests for "Uncommitted and untracked work is measured", "Ignored files are not measured" and "The workspace is left as it was" (branch, HEAD and `git status --porcelain` unchanged, temporary index deleted)
- [x] 3.2 Implement the `:protected_files` and `:diff_size` rules as pure functions over the measured changes and the config; verify with tests for "An existing test is modified", "An existing test is deleted", "A new test is added", "Gate configuration is changed", "Too many changed lines", "Too many changed files", plus a rename of an existing test counting as a deletion

## 4. Running commands

- [x] 4.1 Implement `Smelt.Gate.Command.run(executable, args, cd:, env:, timeout:)`: a dedicated process owns the port (stdin closed, stderr merged), keeps the last 64 KiB of output, monitors the caller, and on timeout or caller exit kills the whole process tree (SIGTERM, 2 s grace, SIGKILL); returns `{:ok, %{exit_status:, output:}}` or `{:error, {:timeout, output}}`; verify with tests for exit status and output, output truncation, a timeout that kills the script and its child process, and a caller that exits mid-run leaving no process behind

## 5. Gate

- [x] 5.1 Implement the `:openspec` and `:checks` rules (OpenSpec through `Smelt.Gate.Command` with `OPENSPEC_TELEMETRY=0`, skipped without `openspec/`, `:openspec_not_found` when the CLI is missing; checks script extracted from `base_sha` to a temporary file and run with `/bin/sh`) and `Smelt.Gate.run/2` with `Smelt.Gate.Result`, rule order and skipping; verify with tests named after the spec for "Every rule passes", "One rule fails", "Invalid OpenSpec artifacts", "Project without OpenSpec", "Checks pass", "Checks fail", "The workspace's copy of the script is ignored", "No checks script", "Checks exceed the timeout", "Protected test modified" (script not run), "Settings from the base commit" (end to end) and `:workspace_missing`; document `run/2`, the rules and the result in the `Smelt.Gate` entry of `docs/architecture.md`

## 6. Smelt's own gate and integration

- [x] 6.1 Add `.smelt/checks.sh` to Smelt (deps, compile with warnings as errors, format check, tests) and run it by hand from the main checkout; verify it exits 0
- [ ] 6.2 Run one manual check in `iex -S mix` against a scratch clone of Smelt: create a workspace, run `Smelt.Gate.run/2` and see it pass; then modify an existing test in the workspace and see `:protected_files` fail with `:checks` skipped; remove the workspace. This is not part of the automated suite
- [ ] 6.3 Update the stage 2 status in `docs/roadmap.md`; verify `mix precommit` and `openspec validate add-deterministic-gate --strict` pass, and every scenario in the spec has a test with the same name

## Workflow follow-up

- Archive the change after review and merge (`openspec archive add-deterministic-gate`).
- Then propose the next stage 2 change: driving one task from the CLI (build with the runner in a workspace, gate, approval, merge).
