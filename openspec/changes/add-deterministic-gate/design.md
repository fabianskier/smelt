# Design

## Context

See `proposal.md` for motivation and `specs/task-gate/spec.md` for the required behavior.

Relevant facts:
- A task's workspace (`openspec/specs/task-workspace/spec.md`) is a git worktree on its own branch, with its base branch and exact base commit (`base_sha`) recorded at creation. The gate compares against `base_sha`, never against the base branch, which may have moved.
- The agent may or may not commit its work, so the gate cannot rely on commits alone.
- A project's checks are slow (minutes) and start trees of processes (`sh` → `mix` → BEAM → `psql`, …). Erlang ports can't start a child in its own process group, and macOS has no `setsid` command.
- `Smelt.Runner.ClaudeCode` already shows the pattern for an OS process that must never outlive its owner: a dedicated process owns the port and kills the OS process on owner exit.

## Goals / Non-Goals

**Goals:**
- Deterministic: the same workspace and base commit always give the same rule outcomes (apart from flaky project tests, which are the project's concern).
- The agent cannot weaken the gate: configuration and checks come from `base_sha`.
- The gate never changes the workspace's git state.

**Non-Goals:**
- Retrying, or asking the agent to fix failures. The caller decides.
- Installing dependencies or setting up databases: the project's `checks.sh` does what it needs.
- Running several gates in parallel with separate ports or databases (stage 5).
- Checking that every OpenSpec scenario has a test (a later rule).
- Broadcasting events or persisting results: the pipeline change will do that around `run/2`.

## Decisions

### 1. API

```elixir
Smelt.Gate.run(%Smelt.Workspace{} = ws, opts)  # {:ok, %Smelt.Gate.Result{}} | {:error, reason}
```

`%Smelt.Gate.Result{status: :pass | :fail, rules: [rule], duration_ms}` where each rule is `%{name: name, status: :pass | :fail | :skipped, details: map}` and `name` is `:protected_files`, `:diff_size`, `:openspec` or `:checks`, always in that order.

Rule details:
- `:protected_files` - `%{violations: [%{path: path, change: :modified | :deleted | :added}]}` (`:added` only under `.smelt/`)
- `:diff_size` - `%{changed_lines:, changed_files:, max_changed_lines:, max_changed_files:}`
- `:openspec` - `%{output: text}`, or `%{reason: :no_openspec_dir | :openspec_not_found}`
- `:checks` - `%{exit_status:, output:}`, or `%{reason: :missing_script | :timeout | :earlier_rule_failed, output: …}`

Errors (`{:error, _}`, no result): `{:invalid_config, message}` for a bad `.smelt/gate.json`, `:workspace_missing` when the workspace directory doesn't exist, and `{:git, …}` for unexpected git failures.

- **Why a result for rule failures and an error for configuration problems:** a rule failure is a verdict on the task's work. A broken `gate.json` or a missing workspace says nothing about the work, and the caller must not treat it as "the agent failed".
- **Why `run/2` is a plain function:** like `Smelt.Workspace`, the gate has no state between calls. Only the checks script needs a process (decision 5).

### 2. Measure changes with a temporary index

1. `GIT_INDEX_FILE=<tmp> git read-tree HEAD` copies the workspace's current commit into a throwaway index file outside the repository.
2. `GIT_INDEX_FILE=<tmp> git add --all` stages every file of the working tree into it, honoring `.gitignore`. Tracked files that match an ignore pattern stay, because they are already in the index.
3. `git diff --cached --no-renames -z --name-status <base_sha>` and `--numstat` against that index give the change list and line counts. Binary files count as one changed file and zero lines.
4. The temporary file is deleted.

- **Why:** it captures committed, uncommitted and untracked work in one diff, with git's own ignore rules, and never touches the real index (the spec forbids changing the workspace).
- **Why `--no-renames`:** a renamed test shows up as a deletion of the old path, which the protected-files rule rejects. With rename detection, a rename plus a rewrite could look like a new file.
- **Alternatives:** `git diff <base_sha>` plus `git ls-files --others` (two sources, and untracked line counts by hand); `git stash` or a temporary commit (both change the workspace).

### 3. Configuration from the base commit

`git cat-file -e <base_sha>:.smelt/gate.json` checks for the file; `git show <base_sha>:.smelt/gate.json` reads it. It is parsed with Elixir's `JSON` and validated strictly: unknown keys, wrong types and non-positive numbers are `{:invalid_config, message}`. Defaults: `test_paths: ["test/"]`, `max_changed_lines: 400`, `max_changed_files: 20`, `timeout_seconds: 900`.

A path is under a test path when it starts with it, so `test/` matches `test/a_test.exs` but not `tests/`. `.smelt/` is always protected and can't be configured away.

### 4. Rule order and skipping

`:protected_files` and `:diff_size` (milliseconds) and `:openspec` (about a second) always run. `:checks` (minutes) runs only if all three passed or were skipped; otherwise it is `:skipped` with `reason: :earlier_rule_failed`.

### 5. Running the checks script

The script is extracted with `git show <base_sha>:.smelt/checks.sh` to a temporary file outside the workspace and run as `/bin/sh <file>`, with the workspace as working directory and stdin closed. Running it through `sh` means it needs no executable bit or shebang.

`Smelt.Gate.Command.run(executable, args, cd:, env:, timeout:)` starts a dedicated process that owns the port and collects the output, keeping only the last 64 KiB. The caller waits for its reply. The dedicated process monitors the caller. On timeout, or if the caller exits, it kills the whole process tree: it reads `ps -A -o pid=,ppid=` once, collects the descendants of the port's OS pid, sends SIGTERM to all of them, waits up to 2 seconds, and sends SIGKILL to any survivor.

- **Why a process tree and not just the pid:** killing `sh` leaves `mix test` and its BEAM running. The checks would keep using CPU and the test database after the gate has reported.
- **Why not a process group:** a port can't call `setsid`/`setpgid`, and macOS has no `setsid` command. A wrapper in another language (`perl -e setpgrp`) would add a dependency for one call.
- **Why not reuse `Smelt.Runner.ClaudeCode.Session`:** it is built around stream-json events and PubSub. The gate needs plain output and a timeout. The pattern is reused, the code is not.

### 6. OpenSpec rule

When `<workspace>/openspec` is a directory, run `openspec validate --all --strict --no-interactive` with the workspace as working directory and `OPENSPEC_TELEMETRY=0`, through `Smelt.Gate.Command` with the checks timeout. The executable is `config :smelt, Smelt.Gate, openspec: "openspec"`. If it is not found, the rule fails with `reason: :openspec_not_found`: a project that uses OpenSpec must be validated.

### 7. `Smelt.Git.cmd/3`

`Smelt.Git.cmd(repo, args, env: [{"NAME", "value"}])` adds variables on top of the base and configured environment. `cmd/2` keeps working unchanged. The gate needs it for `GIT_INDEX_FILE`.

### 8. Tests

- Real git in `tmp_dir` repositories built with `Smelt.GitRepo`, which gains a helper to create a repository with `.smelt/checks.sh` and `.smelt/gate.json`.
- Checks scripts are small shell scripts (`exit 0`, `echo out; exit 3`, `sleep`).
- The timeout test starts `sleep` as a child, writes its pid to a file, and asserts that neither the script's process nor the child is alive afterwards (`kill -0`). It uses `timeout_seconds: 1`.
- The OpenSpec tests use the real `openspec` CLI, which the project already requires (installed by mise), with a minimal valid and an invalid spec.

## Risks / Trade-offs

- [A process that double-forks and is re-parented to init escapes the tree kill] → Accepted: test runners don't daemonize. A sandbox (stage 8) will contain this properly.
- [Smelt's own checks in a workspace use the same `smelt_test` database as the main checkout] → Ecto's SQL sandbox isolates each test's transaction, so runs don't see each other's data. Per-workspace databases come with the gate pool (stage 5).
- [Checks need dependencies, and a fresh worktree has none, so the first run downloads and compiles them] → The project's `checks.sh` runs `mix deps.get`. Sharing a build cache between workspaces is a later optimization.
- [Output is truncated to the last 64 KiB] → The end of a test run holds the failures and the summary, which is what a reviewer needs.
- [The OpenSpec CLI adds about a second per gate (Node start-up)] → Acceptable next to the checks' minutes.
- [A broken checks script at the base commit makes every task fail] → Intended: the task can't fix its own gate. Fixing the script is a separate change, made by a human.
