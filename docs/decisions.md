# Decisions

Each decision records its context, what was chosen and its consequences. When a decision changes, mark it `superseded by …` instead of deleting it.

## Own Elixir/OTP orchestrator instead of Jido

**Status:** accepted (2026-11)
**Context:** Jido offers agent building blocks in Elixir. `jido_harness` was at 3.0.0-rc: it uses ACP and a native C++ helper, has no structured output, and its sessions don't survive restarts. `jido_ai` requires an API key, not the subscription.
**Decision:** Build the orchestration directly on OTP.
**Consequences:** Learning OTP first-hand is a project goal. Jido can be plugged in later as another `Smelt.Runner` implementation.

## OpenSpec as the spec format

**Status:** accepted (2026-11)
**Context:** Options: a custom format, Spec Kit, or OpenSpec.
**Decision:** Use OpenSpec.
**Consequences:**
- A proven format with a validator, oriented to changes/deltas (works for brownfield code), and living specs that prevent spec↔code drift. It is usable by hand today.
- Spec Kit was heavier: rigid phases and a Python setup.
- Costs: it depends on Node (or a binary/brew), its telemetry is opt-out (disabled with `OPENSPEC_TELEMETRY=0`), and v2 is recent → integrate through the CLI with `--json`.

## Claude Code headless instead of the Anthropic API

**Status:** accepted (2026-11)
**Context:** The only Claude access is a Pro subscription, which works only through the Claude Code CLI.
**Decision:** Run Claude Code headless (`claude -p --output-format stream-json`).
**Consequences:** Cost and tokens come from the stream. An API key provider can be added later behind `Smelt.Runner`.

## Human checkpoints instead of approver/intake agents

**Status:** accepted (2026-11)
**Context:** AI approvers spend tokens, and the Pro quota is limited.
**Decision:** The user approves spec, plan and merge.
**Consequences:** Approvals cost no tokens. Autonomy starts at the *assisted* level and moves up based on metrics.

## PostgreSQL, with state in the DB and artifacts in the repo

**Status:** accepted (2026-11)
**Context:** Smelt might become multi-user (a shared server).
**Decision:** Use PostgreSQL (not SQLite) for state; specs and artifacts live in each project's repo.
**Consequences:**
- The same database works locally and on a server. Oban gets its full feature set (LISTEN/NOTIFY, multi-node), and events can be stored as JSONB.
- Development uses Postgres.app (PG 18, local *trust* auth); Docker comes later (sandbox, deploy).
- The connection goes through `DATABASE_URL`, so the backend can change without touching code.

## LiveView now; React later if needed

**Status:** accepted (2026-11)
**Context:** The dashboard needs real-time updates.
**Decision:** Use LiveView, which gives real time without an API.
**Consequences:** All logic lives in `lib/smelt/` (contexts) and events flow over PubSub; the web layer is thin and replaceable. Future options: React islands inside LiveView (`live_react`), Inertia.js, or an SPA + API/Channels (only for multi-user or mobile).

## Private project

**Status:** accepted (2026-11); superseded by "Public repository, all rights reserved"
**Context:** This is a personal tool.
**Decision:** No license, no hex.pm release, private repository.
**Consequences:** If it is ever shared, it will be through private repo access or a closed binary (Burrito). Before that, review Anthropic's terms: users must bring their own Claude Code or API key, never the author's subscription.

## Code and docs in English

**Status:** accepted (2026-11)
**Decision:** Code, docs and OpenSpec artifacts are written in English. Conversations may be in Spanish.

## Take ideas from zazencodes software-factory v2, not code

**Status:** accepted (2026-11)
**Context:** [zazencodes software-factory v2](https://github.com/zazencodes/zazencodes-season-3/tree/main/src/software-factory-claude-code-v2) is a similar pipeline (intake → route → spec → build in worktree + draft PR → gate `checks.sh` → parallel reviewers by risk → approver → merge, max 3 rounds). It is GPLv3.
**Decision:** Reuse its ideas, never its code.

**Adopted:**
- Split between judgment (agents) and mechanism (deterministic scripts).
- Gate before review.
- Protected checks (use the copy from `main`).
- One worktree per job.
- Resumable state.
- A parseable first line in outputs (`STATUS: READY`, `VERDICT: PASS`).

**Changed:**

| zazencodes | Smelt |
|---|---|
| Depends on a live interactive session | Supervised OTP application |
| Opus/Fable and up to 4 reviewers with 3 jobs | Doesn't fit Pro: fewer agents, default model |
| `factory/jobs/` is gitignored and specs get lost | OpenSpec archive |
| Tests not protected | Changes to existing tests are blocked |
| Cost extracted from transcripts | Cost comes from stream-json |
| AI approver with automatic merge | Human approval |
| Static dashboard | LiveView |

## Public repository, all rights reserved

**Status:** accepted (2026-11)
**Context:** Smelt built every task of the public portfolio project `courier`, whose docs describe it; readers can only check that claim if Smelt's code is visible. "Private project" kept it private with no license and asked to review Anthropic's terms before sharing it. Smelt drives the Claude Code CLI with whatever login the user running it has; it holds no keys or subscription of its own.
**Options considered:**
- *Keep it private*: nothing to maintain or explain, but `courier`'s development story stays unverifiable.
- *Public with an open license (MIT, Apache-2.0)*: invites reuse and contributions the author does not want to support.
- *Public, all rights reserved*: readable and verifiable, no permission to reuse; the same choice as `courier`.
**Decision:** Make the GitHub repository public under an "all rights reserved" notice in `LICENSE` (review only, as in `courier`). No hex.pm release, no binaries, no support or contribution process.
**Consequences:**
- Anyone running Smelt must use their own Claude Code login; the README says so, which meets the condition "Private project" set on Anthropic's terms.
- Ideas taken from the GPLv3 zazencodes project stay ideas only ("Take ideas from zazencodes software-factory v2, not code"); publishing changes nothing there.
- The README must describe the current state honestly, including what is parked (the LiveView dashboard) or missing.
- If outside use is ever wanted, a new ADR picks an open license.

