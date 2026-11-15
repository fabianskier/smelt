# Spec Delta

## ADDED Requirements

### Requirement: Isolate the agent from the user's setup
The system SHALL run the agent without the user's own Claude Code settings, loading only the working directory's project and local settings, so that hooks, plugins, skills and MCP servers configured by the user do not apply. The user's login MUST keep working.

#### Scenario: Only project settings are loaded
- **WHEN** an agent is run
- **THEN** it is started with its setting sources limited to project and local

### Requirement: Do not pass the launching session's environment
The system SHALL start the agent without environment variables that belong to a parent Claude Code session or to a terminal integration: `CLAUDECODE`, any variable starting with `CLAUDE_`, `AI_AGENT` and any variable starting with `REX_`. Other variables MUST be kept, and variables the caller passes explicitly MUST be applied on top.

#### Scenario: Parent session variables are removed
- **WHEN** Smelt's environment has `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `AI_AGENT` and `REX_SESSION` set, and an agent is run
- **THEN** none of them is in the agent's environment, while `PATH` and `ANTHROPIC_BASE_URL` keep their values

#### Scenario: Caller variables still apply
- **WHEN** an agent is run with an explicit variable `CLAUDE_CODE_MAX_OUTPUT_TOKENS` from the caller
- **THEN** the agent's environment has that variable with the caller's value
