# Tasks

## 1. Publish

- [x] 1.1 Add `LICENSE` with exactly this text:

      Copyright (c) 2026 Oscar Fabián Cristaldo Guzmán. All rights reserved.

      This source code is published for review only. No permission is granted to
      copy, modify, distribute, sublicense or use it, in whole or in part, without
      the prior written permission of the copyright holder.

  Rewrite `README.md` as described in proposal.md, using `docs/architecture.md`, `docs/decisions.md` and `docs/roadmap.md` for the facts, and these measured numbers from building `courier` (https://github.com/fabianskier/courier): 39 task runs over 12 OpenSpec changes, 36 passed the gate (2 agent failures, 1 stopped by a usage limit), $39.38 in total, median $0.91 per passed task (from $0.16 for a docs task on Sonnet to $4.56 for a frontend task that needed a retry); state that each user runs Smelt with their own Claude Code login and that the LiveView dashboard is parked. Replace "the private repo" in `docs/roadmap.md` with the public repository. Verify `sh .smelt/checks.sh` and `openspec validate publish-repository --strict` pass
