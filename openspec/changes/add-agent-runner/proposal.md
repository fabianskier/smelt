# Proposal

## Why

Every Smelt stage (discovery, build, review) delegates work to a coding agent, but Smelt has no way to run one yet. A single, provider-agnostic way to run an agent and observe its output live is the foundation the rest of the pipeline (state machine, Oban queues, governor, dashboard) builds on.

## What Changes

- New `Smelt.Runner` behaviour: the common contract for running an agent with a prompt and options, emitting normalized events while it runs and returning a final result.
- New normalized event and result structures, independent of any provider's wire format (session start, assistant text, tool use, tool result, rate-limit status, final result).
- New `Smelt.Runner.ClaudeCode` implementation that runs the Claude Code CLI headless in a given working directory, never waits for input, and never leaves the agent's process running after a run ends or is stopped.
- Every event of a run is broadcast over `Phoenix.PubSub` on a per-run topic.
- The final result carries the result text, cost (USD), token usage, number of turns, duration and the agent's session id.
- A run fails with a descriptive error when the CLI exits non-zero, reports an error result, or ends without a result.
- Tests use a fake executable that replays recorded stream-json fixtures; no test calls the real Claude Code CLI.
- Out of scope: the LiveView that displays the stream (separate change `add-run-stream-view`), Oban integration, the usage governor and other providers.

## Capabilities

### New Capabilities

- `agent-runner`: running a coding agent with a prompt in a working directory, streaming normalized events over PubSub, reporting a final result with cost and usage, handling failures, and cleaning up the external process.

### Modified Capabilities

None.

## Impact

- New code under `lib/smelt/runner/` (behaviour, event and result structs, Claude Code implementation, port handling).
- Uses the existing `Smelt.PubSub`; no new runtime dependencies.
- New test support: a fake CLI script and recorded JSONL fixtures under `test/support/`.
- Requires the `claude` executable on the `PATH` at runtime (configurable path); tests do not.
