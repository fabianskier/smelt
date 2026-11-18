# Proposal

## Why

The ADR "Public repository, all rights reserved" (docs/decisions.md) makes the repository public. The README still introduces Smelt as "personal, private", mentions a live dashboard that is parked, and there is no `LICENSE` file; `docs/roadmap.md` refers to "the private repo".

## What Changes

- Add `LICENSE` with the same "all rights reserved, review only" notice as `courier`.
- Rewrite the README for a public reader: what Smelt is and is not; what works today (one task end to end from the command line: worktree, setup, headless Claude Code with limited permissions, deterministic gate, one retry, human approval, merge or discard, usage report and `usage.jsonl`, usage-limit detection); what is parked or missing (the LiveView dashboard, resuming runs, parallel tasks, writing proposals, automatic review); requirements, with the user's own Claude Code login; a short usage example with `mix smelt.task`; the project it built (`courier`, with measured numbers below); and the license.
- Replace "the private repo" wording in `docs/roadmap.md`.
- Documentation and a license file only: no code or requirement changes.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None.

## Impact

`LICENSE` (new), `README.md`, `docs/roadmap.md`.
