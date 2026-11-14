# Design

## Context

Smelt can run an agent (`openspec/specs/agent-runner/spec.md`) in any `cwd`, but it has no per-task place to run it. See `proposal.md` for motivation and `specs/task-workspace/spec.md` for the required behavior.

Relevant facts:
- Target projects are local git repositories (2.40 or later; the dev machine has 2.54). A project's state lives in its repo, and Smelt's runtime state goes in Postgres. Postgres persistence comes with the pipeline change.
- Claude Code loads `CLAUDE.md` files from the working directory **and every parent directory**. Mix, git and editors also look upward.
- The gate (next change) needs each task's base commit to diff against, and needs the copy of protected files from that commit, even after `main` moves.

## Goals / Non-Goals

**Goals:**
- Deterministic names: the same (repo, change, task) always maps to the same directory and branch, so lookup needs no database.
- Never touch the user's checkout.
- Safe to call concurrently for different tasks of the same repo, since stage 5 will do that.

**Non-Goals:**
- Committing, diffing, rebasing, merging.
- Installing dependencies or building in the workspace (`deps`, `_build`, `node_modules`). That is the gate's job.
- Running or disabling the project's git hooks. `git worktree add` runs `post-checkout` as usual.
- Remote operations (`fetch`, `push`). Everything is local.

## Decisions

### 1. API

```elixir
Smelt.Workspace.create(repo, change, task_id, opts)  # {:ok, %Workspace{}} | {:error, reason}
Smelt.Workspace.fetch(repo, change, task_id, opts)   # {:ok, %Workspace{}} | {:error, :not_found | reason}
Smelt.Workspace.list(repo, opts)                     # {:ok, [%Workspace{}]} | {:error, reason}
Smelt.Workspace.remove(repo, change, task_id, opts)  # {:ok, :removed | :branch_kept | :absent} | {:error, reason}
```

`%Smelt.Workspace{repo, change, task_id, path, branch, base, base_sha}`. `repo` is the absolute top-level path of the main checkout.

Options: `:base` (create only, default `"main"`), `:root` (workspaces root, default from config), `:force` (remove only, default `false`).

Errors: `:not_a_repository`, `{:unknown_base, base}`, `:already_exists`, `{:invalid_identifier, :change | :task_id}`, `{:metadata, posix_reason}` when the metadata file can't be written, and `{:git, args, exit_status, output}` for unexpected git failures. `fetch/4` returns `:not_found` for a missing workspace, and the same identifier and `:not_a_repository` errors as `create/4` for bad input, so a typo is not mistaken for a workspace that doesn't exist.

`repo` may be any path inside the project or one of its worktrees. It is resolved to the main checkout (the parent of `git rev-parse --git-common-dir`), so the same project always gets the same hash.

- **Why plain functions, not a GenServer per workspace:** a workspace is state on disk, not a running process. The future pipeline state machine owns the lifecycle and calls these functions.
- **Why `:root` as an option:** tests pass their own `tmp_dir` and stay `async: true` without touching global app env.

### 2. Naming and location

- Branch: `smelt/<change>/<task-id>`, for example `smelt/add-patients/2.1`. The `smelt/` prefix is how `list/2` recognizes managed workspaces.
- Directory: `<root>/<repo-name>-<hash>/<change>/<task-id>`, where `<hash>` is the first 8 hex characters of the SHA-256 of the repo's absolute path, so two repos with the same name don't collide.
- Default root: `$XDG_DATA_HOME/smelt/worktrees`, or `~/.local/share/smelt/worktrees` when it is unset. It can be changed with `config :smelt, Smelt.Workspace, root: …`.
- Validation before any git call: change `^[a-z0-9]+(-[a-z0-9]+)*$`, task id `^[0-9]+(\.[0-9]+)*$`. Together with the hash, this keeps every path inside `root` and every ref valid.

**Why outside the repo, not `<repo>/.smelt/worktrees/`:** a nested worktree would inherit the main checkout's `CLAUDE.md`, which may be stale for the task. It would also show up as untracked files in the user's checkout, unless `.git/info/exclude` were edited, and Mix and editors would see a project inside a project.

### 3. Metadata next to the worktree

Creation writes `<root>/<repo-name>-<hash>/<change>/<task-id>.json` (a sibling of the worktree directory) with `base`, `base_sha` and `repo`. `fetch/4` and `list/2` read it.

- **Why not compute the base commit later:** `git merge-base` gives the wrong answer once the branch is rebased or `main` moves. The base must be recorded when the workspace is created.
- **Why not inside the worktree:** the agent and the gate would see it as an untracked file.
- **Why not `git config branch.<b>.*`:** it writes the user's `.git/config`. The sibling file keeps all of Smelt's writes outside the repo, except git's own worktree bookkeeping.
- A workspace exists only when git lists the worktree with the expected branch **and** the metadata file is present. If either is missing, `fetch` returns `:not_found`, and `remove` cleans up whatever is left.

### 4. Creation steps

Under the repo lock (decision 6):
1. Validate the identifiers.
2. `git rev-parse --show-toplevel` and `--git-common-dir` resolve the main checkout. Failure means `:not_a_repository`.
3. `git rev-parse --verify --quiet <base>^{commit}` gives `base_sha`. Failure means `{:unknown_base, base}`.
4. If the branch exists (`show-ref --verify refs/heads/<branch>`) or the directory exists, return `:already_exists`. This includes a branch kept by an earlier non-forced removal. Re-running that task needs a forced removal first, so finished work is never silently reused or overwritten.
5. `git worktree add -b <branch> <path> <base_sha>`, then write the metadata file.
6. If step 5 fails, roll back: `git worktree remove --force`, `git branch -D` and delete the file. Then return the error.

Using `base_sha` rather than the name `base` in step 5 makes the recorded commit exactly the one checked out, even if `main` moves in between.

### 5. Removal steps

Under the repo lock:
1. If the worktree is registered, run `git worktree remove --force <path>`. `--force` is needed because a workspace normally has untracked build output. If the directory was deleted by hand, run `git worktree prune`.
2. If the branch exists: when `git merge-base --is-ancestor <branch> <base>` succeeds, or `:force` is set, run `git branch -D` and return `:removed`. Otherwise keep the branch and return `:branch_kept`.
3. Delete the metadata file. If nothing existed, return `:absent`.

`git branch -d` is not used, because it checks whether the branch is merged into the *main checkout's HEAD*, not into the base.

### 6. Serialize per repository

Operations that change git state (`create`, `remove`) run inside `:global.trans({{Smelt.Workspace, repo}, self()}, fun)`, keyed on the resolved repo path. `fetch` and `list` don't take the lock.

- **Why:** concurrent `git worktree add` calls in the same repo can fail on git's lock files (`config.lock`, `.git/worktrees/*`). Serializing makes each call behave as if it ran alone, which the spec requires. The lock is held for milliseconds.
- **Alternative:** a GenServer per repo under a Registry. Rejected for now: it adds a supervised process with no other state. If stage 5 needs a per-repo process (merge queue), the lock can move into it.

### 7. Git wrapper

`Smelt.Git.cmd(repo, args)` runs `System.cmd("git", ["-C", repo | args], stderr_to_stdout: true, env: env)` and returns `{:ok, output}` or `{:error, {:git, args, status, output}}`. The base env is `GIT_TERMINAL_PROMPT=0` (never wait for credentials) and `LC_ALL=C`, plus any `config :smelt, Smelt.Git, env: …`.

Errors are classified by explicit checks before acting (steps 2 to 4), not by parsing git's messages, which change between versions.

### 8. Tests

- Real git against repositories created in ExUnit's `@tag :tmp_dir`, and `async: true`.
- `test/support/git_repo.ex` creates a repo with an initial commit on `main`, extra branches and commits, and checkout states such as modified or untracked files.
- Isolation from the developer's machine: `config/test.exs` sets `Smelt.Git` env to `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`, and the helper commits with `-c user.name=… -c user.email=… -c commit.gpgsign=false`. A global `gpgsign` or hook therefore can't break the suite.
- Every test passes `root: tmp_dir/"workspaces"`.

## Risks / Trade-offs

- [A workspace survives a crash between `worktree add` and writing the metadata] → `fetch` reports `:not_found` and `create` reports `:already_exists`. A forced `remove` cleans it up. The pipeline change will run cleanup for orphans found by `list/2` at startup.
- [The user deletes `<root>` by hand] → git keeps stale worktree entries. `remove` runs `git worktree prune`, and they never block a new `create` for a different task.
- [Project hooks run on `post-checkout`] → accepted for now. Hooks are the project's own code. If they become a problem, the gate change can decide to pass `-c core.hooksPath=/dev/null`.
- [`:global.trans` is cluster-wide but Smelt is single-node] → it costs nothing on one node and keeps working if Smelt ever runs on several nodes.
- [Disk use: each workspace is a full checkout] → it shares the object store with the repo, so only the working files are duplicated. Removal after merge keeps this bounded.
