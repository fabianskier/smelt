# Tasks

## 1. Isolation

- [x] 1.1 Add `--setting-sources project,local` to every run in `Smelt.Runner.ClaudeCode`, before the caller's `args:`; verify with the test for "Only project settings are loaded" (fake agent argument log) in a new test file
- [x] 1.2 Implement `ClaudeCode.isolated_env/1` and pass its unset list to the port before the caller's `env:`; verify with unit tests over maps and with `async: false` tests for "Parent session variables are removed" and "Caller variables still apply"; document the isolation in the `Smelt.Runner` entry of `docs/architecture.md`

## 2. Integration

- [x] 2.1 From this Claude Code session, run `Smelt.Runner.ClaudeCode.run/2` once with a short prompt that asks the agent to list its skills, and confirm `rex` and the synced plugin skills are not among them; record the result in `docs/roadmap.md` and remove the isolation item from "Next". Uses a little Claude Pro quota; not part of the automated suite
- [x] 2.2 Verify `mix precommit`, `openspec validate isolate-agent --strict`, and that every scenario in the delta spec has a test with the same name

## Workflow follow-up

- Archive the change after review and merge (`openspec archive isolate-agent`).
