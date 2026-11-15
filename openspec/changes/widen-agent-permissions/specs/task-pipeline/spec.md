# Spec Delta

## MODIFIED Requirements

### Requirement: Limit the agent's permissions
The system SHALL run the agent allowing only reading, searching and editing files, and running `mix` (also prefixed with `MIX_ENV=test`), `elixir`, `erl`, `git` and the project's checks script. Pushing with git MUST be denied.

#### Scenario: Agent permissions
- **WHEN** a task is run
- **THEN** the agent is started with exactly those allowed tools and with `git push` denied
