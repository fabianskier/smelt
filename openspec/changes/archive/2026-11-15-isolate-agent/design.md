# Design

## Context

See `proposal.md`. `Smelt.Runner.ClaudeCode.run/2` starts `claude -p <prompt> --output-format stream-json --verbose <args>` through a port; the port inherits the BEAM's environment, plus the caller's `env:`. A probe with a one-word prompt (2026-11-15) compared a default run with one using `--setting-sources project,local` and without the parent session's variables: no `SessionStart` hook, 17 instead of 40 skills (only built-in ones), no synced plugins, no MCP servers, same OAuth login, $0.039 instead of $0.095.

## Goals / Non-Goals

**Goals:**
- Every agent Smelt runs sees only what the target project configures.
- No channel from the agent back to a Claude Code session that launched Smelt.

**Non-Goals:**
- Changing the agent's permissions (a later change) or commit attribution (kept).
- `--bare`: it would also skip the project's `CLAUDE.md` discovery and, with a subscription, can't log in (it never reads OAuth or the keychain).
- `--strict-mcp-config`: MCP servers that the project itself configures are the project's choice.

## Decisions

### 1. Settings

Prepend `--setting-sources project,local` to the arguments, before the caller's `args:`. Project settings come from the working directory, the task's workspace, so a project's `.claude/settings.json` (permissions, attribution, hooks) applies as the project intends.

### 2. Environment

`ClaudeCode.isolated_env(env)` is a pure function: given the BEAM's environment as a map, it returns `{name, false}` for every variable to remove. The port receives these first, then the caller's `env:`, so an explicit caller variable wins. A variable is removed when its name is `CLAUDECODE` or `AI_AGENT`, or starts with `CLAUDE_` or `REX_`.

- **Why a block list and not an allow list:** an allow list would have to know every variable a toolchain needs (`PATH`, `HOME`, `MIX_*`, `ERL_*`, locale, proxies, mise's variables). The variables that cause trouble are few and recognizable.
- **Why keep `ANTHROPIC_*`:** they configure the API (key, base URL) if the user ever logs in with an API key instead of the subscription.

### 3. Tests

- `Only project settings are loaded`: the fake agent (`test/support/fake_agent`) logs its arguments.
- The environment scenarios run the fake agent with an action that writes `env` to a file. They set variables in the BEAM with `System.put_env/2`, which is global, so they live in a separate `async: false` test module and restore the environment on exit.
- `isolated_env/1` also gets unit tests over plain maps.

## Risks / Trade-offs

- [A future Claude Code feature needs a `CLAUDE_*` variable from the parent] → It would be a deliberate choice to pass it, through the caller's `env:`.
- [The user relies on a user-level setting for agents, such as a custom model] → Put it in the project's `.claude/settings.json`, or pass `--model` through `args:`.
