# Proposal

## Why

In the eight `viborita` tasks, the agent was blocked from harmless commands it needed: checking the toolchain (`elixir --version`, `erl -noshell -eval …`) and running tests in the test environment explicitly (`MIX_ENV=test mix test …`, used to rerun a test it suspected was flaky). It worked around them or gave up on the check. A probe (2026-11-15) confirmed `Bash(mix:*)` does not cover a command prefixed with `MIX_ENV=test`, and that `Bash(elixir:*)`, `Bash(erl:*)` and `Bash(MIX_ENV=test mix:*)` allow them.

## What Changes

- Add `Bash(elixir:*)`, `Bash(erl:*)` and `Bash(MIX_ENV=test mix:*)` to the agent's allowed tools.
- Shell loops (`for …; do …; done`) stay blocked: the agent can run a command several times on its own.
- **Existing test changed on purpose:** the "Agent permissions" test in `test/smelt/task_run_test.exs` asserts the exact allowed-tools list, so it is updated to the new list. No other existing test changes.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `task-pipeline`: the "Limit the agent's permissions" requirement allows `elixir`, `erl` and `MIX_ENV=test mix` as well.

## Impact

- `Smelt.TaskRun` agent arguments and the "Agent permissions" test.
- Security is unchanged in practice: `mix` (already allowed) can run arbitrary code with `mix run -e`. The list prevents accidents; the workspace, the gate and human review are the real safeguards.
