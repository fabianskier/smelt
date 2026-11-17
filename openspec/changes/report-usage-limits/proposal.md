# Proposal

## Why

Two `courier` task runs (2026-11-17) ended when the account hit a usage limit: once the 5-hour limit after 6 turns, once a model that needed usage credits. Smelt reported both as a plain agent failure (`{:exit_status, 1, []}`), as if the work had gone wrong, and its final line said `$0.00` although the token report showed $0.91 spent: the cost of an attempt that fails is not added to the task's cost.

## What Changes

- **Usage limit error**: when the agent ends because a usage limit was reached, the runner returns `{:error, {:usage_limit, result}}` with the agent's message, instead of the exit status. A probe (2026-11-17) shows what the CLI reports then: a `rate_limit_event` with `status: "rejected"`, and a final result with `is_error: true` and `api_error_status: 429`, followed by exit status 1.
- **Task outcome**: such a task run ends with the new status `:usage_limited` (not `:agent_failed`), keeps the workspace, and `mix smelt.task` says the task was stopped by a usage limit, with the agent's message (which says when it resets or what to do).
- **Cost of failed attempts**: an attempt that reported a result before failing (a usage limit or an error result) adds its cost to the task's cost.
- **Not in this change**: resuming a stopped task, waiting for the limit to reset, or switching model automatically.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `agent-runner`: "Fail with a descriptive error" adds the usage-limit case.
- `task-pipeline`: new requirements for stopping on a usage limit and for counting the cost of failed attempts.

## Impact

- `Smelt.Runner.ClaudeCode.Parser` (the `:result` event carries `api_error_status`), `Smelt.Runner.ClaudeCode.Session` (tracks a rejected rate limit; new error), `Smelt.Runner` (error type), `Smelt.TaskRun` (status `:usage_limited`, cost of failed attempts), `Mix.Tasks.Smelt.Task` (messages).
- A new fixture, `usage_limit.jsonl`, recorded from the probe. Existing tests are not modified: their fixtures have no rejected limit.
