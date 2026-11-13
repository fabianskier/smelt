@AGENTS.md

## Smelt

- Project overview: `README.md`. Design: `docs/architecture.md`. Rationale: `docs/decisions.md`. Status and next steps: `docs/roadmap.md`.
- Code, docs and OpenSpec artifacts are written in English; conversation may be in Spanish.
- Changes follow OpenSpec (`openspec/`): propose → apply → archive. Run `openspec validate --strict` before building.
- Keep all domain logic in `lib/smelt/` (contexts) and communicate via PubSub; `lib/smelt_web/` stays a thin layer.

## Git

- Use Conventional Commits: `type(scope): description` in English, imperative mood, lowercase, no trailing period.
  Types: feat, fix, refactor, test, docs, chore, ci, perf, build.
- Do not add `Co-Authored-By` trailers or any Claude/Anthropic attribution to commits or pull requests.
- Only commit or push when explicitly asked.
