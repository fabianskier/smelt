# Proposal

## Why

Agents run by Smelt inherit the setup of whoever launches Smelt. In the first eight real tasks (the `viborita` project), every agent ran the user's `SessionStart` hook, which told it to rename the user's terminal session, and it tried to, wasting turns. It also loaded the user's 40 skills, synced plugins and 8 MCP servers, and received the parent Claude Code session's environment, including a messaging socket and token for that session. A minimal run costs about 60% less without all that ($0.039 instead of $0.095 for a one-word reply).

## What Changes

- Run Claude Code with `--setting-sources project,local`: the target project's settings still apply, the user's own settings (hooks, plugins, skills, MCP servers configured there) do not. The user's login keeps working.
- Remove from the agent's environment the variables of a parent Claude Code session (`CLAUDECODE`, `CLAUDE_*`, `AI_AGENT`) and of terminal integrations (`REX_*`). `ANTHROPIC_*` variables and everything else are kept.
- Applies to every agent run through `Smelt.Runner.ClaudeCode`, so `Smelt.TaskRun` gets it without changes.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `agent-runner`: adds a requirement that the agent runs isolated from the user's own Claude Code setup and from the session that launched Smelt.

## Impact

- `Smelt.Runner.ClaudeCode`: extra arguments and environment for every run. Callers' `args:` and `env:` still apply on top.
- Commit attribution (`Co-Authored-By`) is unchanged: it comes from Claude Code's defaults, which projects can change in their own `.claude/settings.json`.
