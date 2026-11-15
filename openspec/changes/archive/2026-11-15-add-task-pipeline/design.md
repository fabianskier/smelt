# Design

## Context

See `proposal.md` for motivation and `specs/task-pipeline/spec.md` for the required behavior. The building blocks exist and are not changed:
- `Smelt.Runner.ClaudeCode.run(prompt, cwd:, run_id:, args:, env:, executable:)` runs `claude -p … --output-format stream-json --verbose [args]` and broadcasts events on `"run:<run_id>"`. Its result carries the `session_id`, which `--resume <session_id>` continues.
- `Smelt.Workspace.create/fetch/remove` and `Smelt.Gate.run/2`.

The first target project is `~/code/viborita`: a small Elixir library with `.smelt/checks.sh` and an OpenSpec change whose tasks are sized for the gate.

## Goals / Non-Goals

**Goals:**
- One command runs a task and asks for approval; approval merges it into the base branch.
- Domain logic in `lib/smelt/` with progress over PubSub; the mix task only prints and reads the answer.
- The user's checkout is never changed in a way that could lose work.

**Non-Goals:**
- Persisting runs in Postgres, resuming after a crash, or running tasks from an Oban queue (stage 3).
- Running several tasks or a whole change (stage 5), or picking the next task automatically.
- Pushing to a remote or opening pull requests (stage 8).
- A web UI (the `/runs` dashboard stays parked).

## Decisions

### 1. API

```elixir
id = Smelt.TaskRun.new_id()
:ok = Smelt.TaskRun.subscribe(id)                       # optional, before run/4
Smelt.TaskRun.run(repo, change, task_id, id: id, base: "main", root: …, runner: [...])
# {:ok, %Smelt.TaskRun{}} | {:error, reason}
Smelt.TaskRun.merge(%Smelt.Workspace{}, opts)          # {:ok, %{base: base, sha: sha}} | {:error, reason}
Smelt.TaskRun.discard(repo, change, task_id, opts)     # {:ok, :removed | :absent} | {:error, reason}
```

`%Smelt.TaskRun{id, workspace, task, status, attempts, gate, cost_usd}`:
- `status` is `:passed`, `:gate_failed` or `:agent_failed`.
- `attempts` lists each attempt: `%{number, run_id, result}`, where `result` is the runner's `{:ok, %Result{}}` or `{:error, reason}`.
- `gate` is the last `%Smelt.Gate.Result{}`, or `nil` when the agent failed.
- `task` is `%{id, description}`.

`{:error, _}` from `run/4` means the task never started: `{:invalid_identifier, _}`, `:not_a_repository`, `{:unknown_base, _}`, `:already_exists` (from the workspace), `:change_not_found`, `:task_not_found`, `:task_done`; or the gate could not run (`{:gate_error, reason}`), in which case the workspace is kept.

Options: `:id`, `:base`, `:root` (passed to the workspace), `:runner` (extra options for `Smelt.Runner.ClaudeCode.run/2`, such as `:executable` and `:env` in tests), `:gate` (options for `Smelt.Gate.run/2`).

- **Why `merge/2` and `discard/4` are separate calls:** approval happens outside Smelt, at a human's pace. `run/4` returns everything needed to decide; the workspace on disk is the only state between the calls.

### 2. Reading the task

`git show <base_sha>:openspec/changes/<change>/tasks.md`, then the first line matching `- [ ] <id> <description>` or `- [x] <id> …` (any case and spacing inside the brackets, as OpenSpec reads them). A missing file is `:change_not_found`. The workspace is created first, so the task is read at exactly its `base_sha`; on any of these errors it is removed again (forced: it has no work yet).

### 3. Prompt

```
You are implementing task <id> of the OpenSpec change "<change>" in this repository.

Task <id>: <description>

Read openspec/changes/<change>/proposal.md, design.md, the specs under
openspec/changes/<change>/specs/ and tasks.md before you start.

Rules:
- Implement only task <id>. Do not start other tasks.
- Do not modify or delete existing tests, and do not change anything under .smelt/.
- When done, mark task <id> as done in openspec/changes/<change>/tasks.md.
- Run `sh .smelt/checks.sh` and fix every failure until it passes.
- Commit your work with a Conventional Commit message.
```

The retry prompt, sent with `--resume <session_id>`, lists each failed rule with its details (violations, counts and maximums, or the last lines of output) and asks the agent to fix them, run the checks and commit.

### 4. Agent permissions

```
--permission-mode acceptEdits
--allowedTools Read Edit Write Glob Grep "Bash(mix:*)" "Bash(git:*)" "Bash(sh .smelt/checks.sh)"
--disallowedTools "Bash(git push:*)"
```

In headless mode, a tool that is not allowed is denied rather than asked about, so this list is the whole permission set. The worktree isolates the repository's files; the command list limits what else the agent can do on the machine.

### 5. Retry

One retry, in the same session (`--resume`), so the agent keeps its context of what it already did. The runner's run id for attempt `n` is `"<task run id>:<n>"` (`TaskRun.agent_run_id/2`), so the CLI can subscribe to both attempts before the run starts. No retry after an agent error: an error (crash, usage limit, missing CLI) won't be fixed by asking again.

### 6. Merge

1. **Commit leftovers:** if `git status --porcelain` in the workspace is not empty, `git add --all` and commit `chore(smelt): commit remaining work of task <id>`. The gate already checked these files.
2. **Base moved?** If the base branch's tip is not `base_sha`, run `git rebase <base>` in the workspace. On failure, `git rebase --abort` and return `:rebase_conflict`. Then run the gate again with `base_sha` set to the new tip; a failure returns `{:gate_failed, result}`.
3. **Fast-forward the base:** find the worktree that has the base branch checked out (`git worktree list --porcelain`).
   - Found: if `git status --porcelain --untracked-files=no` there is not empty, return `{:dirty_checkout, path}`; otherwise `git merge --ff-only <branch>` there, which updates its files.
   - Not found: `git update-ref refs/heads/<base> <task sha> <old base sha>`, which also fails if the base moved meanwhile.
4. **Remove** the workspace (`Smelt.Workspace.remove/4`); the branch is now merged, so it is deleted.

Steps 1 to 3 don't take the workspace's per-repo lock: they change the task's branch and the base branch, not git's worktree list, and the CLI runs one task at a time. The merge queue (stage 5) will serialize merges.

- **Why fast-forward only:** the base branch's history stays linear, like Smelt's own, and a fast-forward can't create a merge conflict in the user's checkout.
- **Why refuse a dirty checkout instead of stashing:** stashing and re-applying the user's work can conflict or lose it. Refusing costs one manual step.
- **Why untracked files are not checked:** `git merge --ff-only` refuses on its own when an untracked file would be overwritten, and other untracked files are unaffected.

### 7. Events

Topic `"task_run:<id>"`, message `{Smelt.TaskRun, id, event}`, where `event` is one of:
`{:workspace_created, ws}`, `{:agent_started, attempt, run_id}`, `{:agent_finished, attempt, result}`, `{:gate_started, attempt}`, `{:gate_finished, attempt, gate_result}`, `{:finished, task_run | {:error, reason}}`.

### 8. CLI

`mix smelt.task REPO CHANGE TASK_ID [--base BRANCH] [--discard]` starts the application, subscribes to the task run and its agent runs, runs the task in a `Task`, and prints events as they arrive: agent text, tool names with a short summary of their input, the gate's rule outcomes, and the cost. For a passed task it prints `git diff --stat <base_sha>..<branch>` and asks `Merge into <base>? [y/N]`. Yes calls `merge/2`; anything else prints where the workspace is and how to discard it. The exit status is non-zero when the task did not pass or the merge failed.

### 9. Tests

- `test/support/fake_agent` (new) plays the agent: it runs the shell snippet in `FAKE_AGENT_FIRST`, or in `FAKE_AGENT_RESUMED` when its arguments contain `--resume`, inside the workspace; appends its arguments to `FAKE_AGENT_ARGS_LOG`; and prints a stream-json `system` init event and a success `result` with a fixed session id.
- Target projects are `Smelt.GitRepo.gate_project!/2` repositories with an OpenSpec change and `tasks.md` added.
- `config/test.exs` adds `GIT_AUTHOR_NAME/EMAIL` and `GIT_COMMITTER_NAME/EMAIL` to `Smelt.Git`'s environment, since Smelt commits leftovers and rebases, and the global git config is ignored in tests.
- The mix task is tested with `ExUnit.CaptureIO` providing the answer on stdin.

## Risks / Trade-offs

- [The agent ignores the prompt and works on other tasks] → The gate's diff limit bounds the damage, and the human sees the diff before approving.
- [`Bash(git:*)` allows destructive git commands in the workspace, such as `reset --hard`] → They only affect the task's branch and worktree. `push` is denied.
- [The agent doesn't commit] → Leftovers are committed on merge with a generic message.
- [The retry costs a second session of Pro quota] → Limited to one, as decided.
- [Two terminals run the same task] → The second fails with `:already_exists` from the workspace.
- [The CLI process is killed mid-run] → The runner kills the agent (its owner died), and the gate kills its checks. The workspace stays; `--discard` removes it.
