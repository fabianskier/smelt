# Proposal

## Why

Smelt shows each task's cost and turns, but not where the tokens go: how much is fresh input, cached context or output, and which tools filled the agent's context. Without that, changes meant to lower token use (`reduce-agent-token-use`) cannot be measured, and the next ones are guesses.

## What Changes

- **Token report**: when a task run ends, `mix smelt.task` prints the tokens of the whole run (input, cache creation, cache read, output), its turns, cost and model, and the agent's tool calls grouped by tool, with the number of calls and the size of the output each tool returned to the agent, largest first.
- **Usage record**: the same data is appended as one JSON line per task run to `usage.jsonl` under the workspaces root, so runs can be compared over time.
- The runner already reports token usage in its result (`agent-runner`: "Report cost and usage in the result"); this change only collects and shows it.
- **Not in this change**: per-turn usage, budgets or limits, and storing usage in the database (stage 3).

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `task-pipeline`: new requirements for the token report and the usage record of the terminal command.

## Impact

- New `Smelt.TaskRun.Usage` (pure accumulator over runner events, report lines, record entry and file append); `Mix.Tasks.Smelt.Task` feeds it the events it already follows.
- A new file, `usage.jsonl`, next to the task workspaces (by default under `~/.local/share/smelt/worktrees`). It holds repository paths, change and task ids and counts; no prompts, outputs or secrets.
- Tool output size is counted in characters, as an approximation of the tokens each tool added to the context: the CLI does not report tokens per tool.
- Existing tests are not modified.
