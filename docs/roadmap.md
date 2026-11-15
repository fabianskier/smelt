# Roadmap

## Build path

1. **Skeleton**: Phoenix + Postgres + Oban; `Smelt.Runner` (behaviour + Claude Code implementation) with its stream visible in LiveView.
2. **One task end to end**: worktree → build → gate → approval → merge.
3. **Robustness**: per-provider governor, router, per-provider queues, resume after a crash or usage limit.
4. **Earlier stages**: idea → discovery → proposal/spec → tasks (OpenSpec).
5. **Real concurrency**: dependency graph + merge queue.
6. **Automatic review, retro and metrics.**
7. *(Optional)* Local provider (Ollama) for summaries and commit messages.
8. **Later**: GitHub integration (`gh`), a Rust sandbox for running tests (separate binary via Port, or Rustler), code indexing with tree-sitter.

## Current status

Stage 1 (skeleton) complete for CLI use. Stage 2 complete for CLI use: one task end to end with `mix smelt.task`.

**Done:**
- Environment (mise with Erlang 29.1.2, Elixir 1.20.5, Node, OpenSpec 2.0.0) and the Phoenix 1.8 project, generated with `mix phx.new . --app smelt --no-mailer --no-gettext`. The `smelt_dev` and `smelt_test` databases exist.
- 1.4: first commit, pushed to the private repo `github.com/fabianskier/smelt`.
- 1.5: `openspec init --tools claude`, project rules in `openspec/config.yaml`, `CLAUDE.md`, and docs split into `README.md` + `docs/`.
- 1.6: `DATABASE_URL` set in `mise.toml` `[env]` and read in `config/runtime.exs` (dev only; tests keep `smelt_test` from `config/test.exs`).
- 1.7: Oban 2.24 (Postgres, Basic engine, migration v14) with queues `claude: 1`, `local: 1`, plus Pruner (7 days) and Lifeline plugins. Tests use `testing: :manual`.
- 1.8a: OpenSpec change `add-agent-runner` (archived 2026-11-13): `Smelt.Runner` behaviour, Claude Code implementation via a supervised `Port` session, events over PubSub, cleanup of the agent process. Spec: `openspec/specs/agent-runner/spec.md`.
- OpenSpec change `widen-agent-permissions`: task agents may also run `elixir`, `erl` and `MIX_ENV=test mix`, which `viborita`'s agents needed (probe: `Bash(mix:*)` doesn't cover a `MIX_ENV=test` prefix). Shell loops stay blocked. Spec: `openspec/specs/task-pipeline/spec.md`.
- 2.1: OpenSpec change `add-task-workspace` (archived 2026-11-13): `Smelt.Git` wrapper and `Smelt.Workspace` (`create`, `fetch`, `list`, `remove`), one git worktree per task outside the project, with base commit metadata and a per-repo lock. Checked end to end against a scratch clone with a real Claude Code run. Spec: `openspec/specs/task-workspace/spec.md`.
- 2.2: OpenSpec change `add-deterministic-gate` (archived 2026-11-15): `Smelt.Gate.run/2` checks a task workspace without AI (protected tests and `.smelt/`, diff size, `openspec validate --strict`, the project's `.smelt/checks.sh` with a timeout that kills the whole process tree), with configuration read from the task's base commit. Smelt has its own `.smelt/checks.sh`. Checked end to end on a scratch clone of Smelt (pass in 44 s from a fresh worktree; a modified test fails at once). Spec: `openspec/specs/task-gate/spec.md`.
- 2.3: OpenSpec change `add-task-pipeline` (archived 2026-11-15): `Smelt.TaskRun` (workspace → Claude Code with limited permissions → gate → one resumed retry → merge or discard, with progress over PubSub) and `mix smelt.task REPO CHANGE TASK_ID [--merge | --discard]`. First real run (2026-11-15): task 1.1 of `add-game-logic` in `~/code/viborita` passed the gate on the first attempt (11 turns, $0.40 equivalent, 271 lines in 4 files); declined at the prompt to leave the approval to a human. Spec: `openspec/specs/task-pipeline/spec.md`.
- OpenSpec change `clarify-new-tests-prompt`: the protected-files rule stays strict (any change to an existing test file fails the gate, since added lines alone can disable a test), and the task prompt now tells the agent to put new tests in new files. In `viborita`, 1 of 8 tasks needed a retry for this. Spec: `openspec/specs/task-pipeline/spec.md`.
- OpenSpec change `isolate-agent`: every agent runs with `--setting-sources project,local` and without the launching session's `CLAUDECODE`, `CLAUDE_*`, `AI_AGENT` and `REX_*` variables. Before it, all eight `viborita` tasks ran the user's Rex `SessionStart` hook and tried to rename the user's session, and agents received a messaging socket to the parent Claude Code session. Checked for real (2026-11-15): the agent lists only built-in and project skills (no `rex`, no synced plugins) and sees none of those variables; a one-line reply costs about 60% less. Spec: `openspec/specs/agent-runner/spec.md`.

**Next:**
1. **Stage 3**: persistence and resuming, or dogfooding Smelt's own changes with `mix smelt.task`.

**Notes:**
- 1.8b (`/runs` web dashboard) is parked: complete (15/15 tasks, tests passing) on the unmerged branch `add-run-stream-view`, kept for later. Decision (2026-11-13): use Smelt from the CLI for now.
- Hex, rebar3 and `phx_new` live inside mise's Elixir install: reinstall them when the Elixir version changes.

## Later

- **AI paper radar**: arXiv (cs.AI/CL/SE/LG), HF Daily Papers and Semantic Scholar → filter by interests (cheap or local model) → criteria-oriented summary (claim, evidence vs. inflated benchmark, reproducibility, impact today) → digest. Oban jobs; reuses Smelt's Runner and router.
- **Claude Code skills** in `~/.dotfiles/claude/` (stowed into `~/.claude`):
  - `vale-la-pena`: evaluates new tools → adopt / try / ignore, with a decision log.
  - `ponerme-al-dia`: a learning path anchored to what I already know, with a mini project and primary sources.
  - `repeticiones`: analyzes zsh and Claude Code history → proposes an alias, script or skill, or says explicitly that it isn't worth it.
- **Rust**: only with a concrete reason (test sandbox, tree-sitter).
