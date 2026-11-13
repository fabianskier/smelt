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

- **`Smelt.Runner` (behaviour)**: common interface for agents (`run/2`, streamed events, result).
  - Initial implementation: Claude Code CLI via `Port` → `claude -p --output-format stream-json --verbose`, parsing JSON events and broadcasting them over PubSub. Cost and tokens come in the stream.
  - Future: local model (Ollama), Anthropic API key, `jido_harness` (Codex, Gemini CLI, etc.).
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
