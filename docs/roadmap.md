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

Stage 1 (skeleton).

**Done:**
- Environment (mise with Erlang 29.1.2, Elixir 1.20.5, Node, OpenSpec 2.0.0) and the Phoenix 1.8 project, generated with `mix phx.new . --app smelt --no-mailer --no-gettext`. The `smelt_dev` and `smelt_test` databases exist.
- 1.4: first commit, pushed to the private repo `github.com/fabianskier/smelt`.
- 1.5: `openspec init --tools claude`, project rules in `openspec/config.yaml`, `CLAUDE.md`, and docs split into `README.md` + `docs/`.

**Next:**
1. **1.6:** `DATABASE_URL` in `config/runtime.exs`, with its value in `mise.toml` (`[env]`).
2. **1.7:** add Oban.
3. **1.8:** first OpenSpec change: `Smelt.Runner` (behaviour + Claude Code implementation via Port) and the stream in LiveView.

**Notes:**
- Hex, rebar3 and `phx_new` live inside mise's Elixir install: reinstall them when the Elixir version changes.

## Later

- **AI paper radar**: arXiv (cs.AI/CL/SE/LG), HF Daily Papers and Semantic Scholar → filter by interests (cheap or local model) → criteria-oriented summary (claim, evidence vs. inflated benchmark, reproducibility, impact today) → digest. Oban jobs; reuses Smelt's Runner and router.
- **Claude Code skills** in `~/.dotfiles/claude/` (stowed into `~/.claude`):
  - `vale-la-pena`: evaluates new tools → adopt / try / ignore, with a decision log.
  - `ponerme-al-dia`: a learning path anchored to what I already know, with a mini project and primary sources.
  - `repeticiones`: analyzes zsh and Claude Code history → proposes an alias, script or skill, or says explicitly that it isn't worth it.
- **Rust**: only with a concrete reason (test sandbox, tree-sitter).
