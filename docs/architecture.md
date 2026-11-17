# Architecture

## Overview

Smelt splits the work in three:

- **Smelt (Elixir/OTP) orchestrates**: states, queues, concurrency, gates, approvals, dashboard.
- **Claude Code executes**: discovery, specs, implementation, review (via headless `claude -p`).
- **OpenSpec defines the specs**: format and lifecycle of changes (Spec-Driven Development).

Judgment belongs to agents; mechanism belongs to deterministic Elixir code.

## Workflow

```
Idea → Discovery → Proposal/Spec → Tasks → [per task] Build → Gate → Review → Merge+Archive → Retro
                    ✋ user         ✋ user               Claude   Elixir  Claude   ✋ user
```

OpenSpec artifacts are versioned in each project's repo:

```
openspec/
  specs/<capability>/spec.md          # current truth of the system (living specs)
  changes/<change>/
    proposal.md                       # Why / What Changes / Capabilities / Impact
    design.md                         # optional
    tasks.md                          # - [ ] 1.1 ... (checklist)
    specs/<capability>/spec.md        # deltas: ADDED / MODIFIED / REMOVED / RENAMED
  changes/archive/YYYY-MM-DD-<change>/
```

Requirement format: `### Requirement: X` with SHALL/MUST, plus `#### Scenario: Y` (exactly four `#`) with **WHEN/THEN**. Every `Scenario` must have a test (ExUnit or other). `openspec validate --strict` is part of the gate.

Stage mapping:

| OpenSpec | Smelt |
|---|---|
| explore / propose | Discovery → Claude generates proposal + deltas + tasks → user approves |
| validate --strict | Spec gate before building |
| apply | Per-task build in a git worktree; Smelt tracks state by reading `tasks.md` |
| — | Test gate: every `Scenario` has a test; existing tests are protected |
| — | Review: code vs. deltas |
| archive | On merge → living specs updated (prevents spec↔code drift) |

**Levels by size** (to avoid bureaucracy): *fix* = task only · *small feature* = short proposal · *large feature* = full flow.

## Components

**Stack:** Phoenix 1.8 + LiveView · PostgreSQL 18 (connection via `DATABASE_URL`) · Oban (Postgres engine) · local git (worktrees + merge) · OpenSpec CLI (`--json`).

- **`Smelt.Runner` (behaviour)** *(implemented)*: common interface for agents. Behavior contract: `openspec/specs/agent-runner/spec.md`.
  - API: `run(prompt, cwd: …, run_id: …, args: …, env: …)` blocks and returns `{:ok, %Smelt.Runner.Result{}}` (text, cost, tokens, turns, duration, session id) or `{:error, reason}`. To follow a run: `new_run_id/0` → `subscribe/1` → `run/2`; `stop/1` cancels it.
  - Events, broadcast on `"run:<id>"` as `{Smelt.Runner, run_id, %Smelt.Runner.Event{}}`: `:session_started`, `:text`, `:tool_use`, `:tool_result`, `:rate_limit` (one per usage window), `:result`, and always a final `:finished`.
  - `Smelt.Runner.ClaudeCode`: one `Session` GenServer per run (`:temporary`, under `Smelt.Runner.Supervisor`, registered in `Smelt.Runner.Registry`) that owns a `Port` to `claude -p --output-format stream-json --verbose`, with stdin closed and stderr captured. The agent's OS process is killed (SIGTERM, then SIGKILL) on stop, on caller exit and on shutdown. Tests use `test/support/fake_claude`, never the real CLI.
  - Isolation: every run loads only the working directory's project and local settings (`--setting-sources project,local`), so the user's own hooks, plugins, skills and MCP servers don't apply (login does), and its environment drops `CLAUDECODE`, `CLAUDE_*`, `AI_AGENT` and `REX_*` from the session that launched Smelt (`ClaudeCode.isolated_env/1`); the caller's `env:` applies on top.
  - Future: local model (Ollama), Anthropic API key, `jido_harness` (Codex, Gemini CLI, etc.).
- **`Smelt.Workspace`** *(implemented)*: an isolated git worktree per task, so an agent never touches the user's checkout or another task. Plain functions over state on disk, no process. Behavior contract: `openspec/specs/task-workspace/spec.md`.
  - Identity: a workspace is (repo, change, task id). The change must be kebab-case and the task id dot-separated numbers (`2.1`); anything else is `{:invalid_identifier, :change | :task_id}`, checked before any git call.
  - Naming: branch `smelt/<change>/<task-id>`; directory `<root>/<repo-name>-<hash8>/<change>/<task-id>`, where `<hash8>` is the start of the SHA-256 of the repo's absolute path. Names are deterministic, so a workspace is found again without a database.
  - Location: outside the project, so the agent doesn't inherit the checkout's `CLAUDE.md` and the user's `git status` stays clean. `<root>` is the `:root` option, else `config :smelt, Smelt.Workspace, root: …`, else `$XDG_DATA_HOME/smelt/worktrees`, else `~/.local/share/smelt/worktrees`.
  - Metadata: `<…>/<task-id>.json`, a sibling of the workspace directory (invisible to the agent and the gate), records `repo`, `base` and `base_sha`: the exact commit the task started from, which the gate diffs against.
  - `create(repo, change, task_id, base: "main", root: …)` returns `{:ok, %Smelt.Workspace{repo, change, task_id, path, branch, base, base_sha}}`. `repo` may be any path inside the project or one of its worktrees; it is resolved to the main checkout. It checks before acting (repo, base commit, existing branch or directory), runs `git worktree add -b <branch> <path> <base_sha>`, then writes the metadata; if a later step fails, it removes the worktree, branch and metadata again. Errors: `{:invalid_identifier, _}`, `:not_a_repository`, `{:unknown_base, base}`, `:already_exists`, `{:metadata, posix}`, `{:git, args, status, output}`.
  - `fetch(repo, change, task_id, root: …)` returns the same struct `create` returned, or `{:error, :not_found}`. A workspace exists only when git lists a worktree on its branch **and** its metadata file is present.
  - `list(repo, root: …)` returns `{:ok, [%Smelt.Workspace{}]}` sorted by change and task id. Only worktrees on a `smelt/<change>/<task-id>` branch **with** a metadata file are listed, so worktrees and branches the user made by hand are ignored.
  - `remove(repo, change, task_id, root: …, force: false)` deletes the directory (uncommitted and untracked files included, via `git worktree remove --force`, or `git worktree prune` if the directory was deleted by hand) and the metadata. The branch is deleted only when `git merge-base --is-ancestor <branch> <base>` succeeds or `force: true`; otherwise it is kept so unmerged work is never lost. Returns `{:ok, :removed | :branch_kept | :absent}`. A kept branch blocks `create` for that task until a forced removal.
  - Concurrency: `create` and `remove` run under a per-repo `:global.trans` lock, so their check-then-act is atomic (two creations of the same task give one workspace and one `:already_exists`). `fetch` and `list` don't lock.
  - Git runs through `Smelt.Git.cmd/3` (`git -C <repo>`, stderr merged, `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, plus per-call `env:`). Tests use real git in `tmp_dir` repos built with `test/support/git_repo.ex`, isolated from the developer's git config.
- **`Smelt.Gate`** *(implemented)*: decides without AI whether a task workspace's changes are acceptable. Behavior contract: `openspec/specs/task-gate/spec.md`.
  - Project configuration lives in the project's repo and is always read from the workspace's `base_sha`, so the agent can't weaken its own gate: `.smelt/checks.sh` (required) and `.smelt/gate.json` (optional). `.smelt/` itself is always protected.
  - `.smelt/gate.json` settings, all optional: `test_paths` (default `["test/"]`, prefix match), `max_changed_lines` (400, added plus deleted), `max_changed_files` (20), `timeout_seconds` (900, for the checks and OpenSpec validation). Unknown keys, wrong types and non-positive numbers make the gate return `{:error, {:invalid_config, message}}` instead of a result (`Smelt.Gate.Config`).
  - `Smelt.Gate.run(workspace, openspec: …)` returns `{:ok, %Smelt.Gate.Result{status: :pass | :fail, rules: [...], duration_ms}}`, or `{:error, {:invalid_config, _} | :workspace_missing | {:git, …}}` for problems that say nothing about the task's work. It only reports; retrying is the caller's decision.
  - Changes are measured against `base_sha` through a temporary index (`read-tree HEAD`, `add --all`, `diff --cached --no-renames`), so committed, uncommitted and untracked work counts, `.gitignore` is honored, and the workspace's real index is never touched (`Smelt.Gate.Changes`). A rename counts as deleting the old path.
  - Rules, always in this order, each `%{name, status: :pass | :fail | :skipped, details}`:
    1. `:protected_files` - fails when a file under `test_paths` that existed at `base_sha` is modified, deleted or renamed, or anything under `.smelt/` changes; lists each violation.
    2. `:diff_size` - fails above `max_changed_lines` or `max_changed_files`; reports counts and maximums.
    3. `:openspec` - `openspec validate --all --strict --no-interactive` in the workspace; skipped without `openspec/`, fails with `:openspec_not_found` if the CLI is missing.
    4. `:checks` - the base commit's `.smelt/checks.sh`, extracted to a temp file and run with `/bin/sh` in the workspace (without Smelt's `MIX_ENV`); fails on a non-zero exit, `:timeout` or `:missing_script`. Skipped with `:earlier_rule_failed` when any earlier rule failed.
  - `Smelt.Gate.Command` runs the checks and OpenSpec: a dedicated process owns the port (stdin closed, last 64 KiB of output kept) and, on timeout or if the caller exits, kills the whole process tree found with `ps` (SIGTERM, 2 s, SIGKILL).
- **`Smelt.TaskRun`** *(implemented)*: one task of an OpenSpec change end to end, ties together the runner, the workspace and the gate. Behavior contract: `openspec/specs/task-pipeline/spec.md`.
  - `run(repo, change, task_id, id:, base:, root:, model:, runner: […], gate: […])`: creates the workspace, reads the task from `openspec/changes/<change>/tasks.md` at `base_sha` (`Smelt.TaskRun.TaskList`), runs Claude Code with the task prompt (`Smelt.TaskRun.Prompt`), and runs the gate. If the gate fails, it resumes the same session once (`--resume <session_id>`) with the failed rules and gates again. Returns `{:ok, %Smelt.TaskRun{status: :passed | :gate_failed | :agent_failed, task, workspace, attempts, gate, cost_usd}}`, always keeping the workspace for review; or `{:error, reason}` when the task never started (`:change_not_found`, `:task_not_found`, `:task_done`, the workspace's errors; no workspace left) or `{:gate_error, reason}`.
  - Agent permissions (headless: anything else is denied): `--permission-mode acceptEdits --allowedTools Read Edit Write Glob Grep "Bash(mix:*)" "Bash(MIX_ENV=test mix:*)" "Bash(elixir:*)" "Bash(erl:*)" "Bash(git:*)" "Bash(openspec validate:*)" "Bash(chmod:*)" "Bash(sh .smelt/checks.sh)" --disallowedTools "Bash(git push:*)"`.
  - Token use: the prompt tells the agent to run only the tests it touched while working, to run `sh .smelt/checks.sh` once at the end (again only after fixing a failure) instead of other full-suite commands, because the gate runs the checks and the OpenSpec validation anyway, and never to retry or work around a denied command. `model:` (`mix smelt.task ... --model NAME`) adds `--model NAME` to every attempt, so a documentation-only task can run on a cheaper model; without it the CLI's default model applies.
  - `merge(workspace, root:, gate:)` on approval: refuses `{:dirty_checkout, path}` if the base branch is checked out with uncommitted tracked changes; commits leftovers (`chore(smelt): commit remaining work of task <id>`); if the base moved, rebases (`:rebase_conflict` after `rebase --abort`) and gates again against the new base (`{:gate_failed, result}`); fast-forwards the base with `merge --ff-only` in the checkout that has it (updating its files) or `update-ref <new> <old>` if none has it; removes the workspace. Returns `{:ok, %{base, sha}}`; on error the base branch is unchanged and the workspace kept. History stays linear.
  - `discard(repo, change, task_id, root:)` removes the workspace and its branch (forced).
  - Events on `"task_run:<id>"` as `{Smelt.TaskRun, id, event}`: `{:workspace_created, ws}`, `{:agent_started, n, run_id}`, `{:agent_finished, n, result}`, `{:gate_started, n}`, `{:gate_finished, n, gate}`, `{:finished, result}`. The agent's own events go to `Smelt.Runner.topic(TaskRun.agent_run_id(id, n))`; both ids are known before the run, so subscribers miss nothing.
- **State machine** per change/task: GenServer under a DynamicSupervisor + Registry, persisted in Postgres and resumed after a crash or restart.
- **Per-provider capacity**: one Oban queue per provider (`queues: [claude: 1, local: 1]`, changeable at runtime with `Oban.scale_queue/1`).
- **Per-provider governor** (GenServer): detects the usage limit, pauses *only that* queue and resumes it when the limit lifts.
- **Router** by stage/risk, configurable with fallback:
  ```elixir
  routing: %{
    discovery: [:claude], build: [:claude], review: [:claude],
    summarize: [:local, :claude], triage: [:local, :claude]
  }
  ```
- **Deterministic gate** (Elixir, no AI): runs the project's checks and `openspec validate --strict`, blocks changes to existing tests and protected paths (using the copy from `main`), and limits diff size.
- **Task dependency graph** (from `tasks.md`): only independent tasks run in parallel.
- **Serialized merge queue**: one merge at a time, rebasing on `main` and running the gate again before merging.
- **Gate pool**: tests run in parallel with per-task ports.
- **LiveView dashboard** on localhost: live agent stream, one-click approve/reject, cost and tokens per task.
- **Smelt state** in `.smelt/` per project; user preferences in `~/.config/smelt/`. Credentials are never stored.

Rule: all logic lives in `lib/smelt/` (contexts) and events flow over PubSub; `lib/smelt_web/` is a thin, replaceable layer.

## Concurrency and providers

Concurrency is in the architecture from day one; capacity is configuration.

| Plan | Capacity |
|---|---|
| Claude Pro (today) | `claude: 1`, `local: 1` |
| Claude Max | `claude: 2–3` |
| API key | provider with a dollar budget |

**Local models** (~7–14B quantized on 16 GB) are not good enough for multi-file agentic builds. They handle mechanical work to save Claude quota: summarizing test logs, commit messages, triage, simple review checks.

On Pro: the plan's default model, no expensive models pinned; fewer agents and more human checkpoints.

## Autonomy levels

1. **Assisted** (start): the user approves spec, plan and merge.
2. **Supervised**: auto-merge for low risk.
3. **Autonomous**: no human review; relies on automated verification.

Moving up a level means changing the per-risk policy in the state machine, justified by metrics (gate failures, rounds per task).

## Constraints

- **Claude Pro subscription**: usage limits (5-hour windows plus a weekly cap). It can only be used through the Claude Code CLI; there is no API key.
- **16 GB RAM** (Apple M4): limits local models to roughly 7–14B quantized.
