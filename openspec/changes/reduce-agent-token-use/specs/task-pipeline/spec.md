# Spec Delta

## MODIFIED Requirements

### Requirement: Limit the agent's permissions
The system SHALL run the agent allowing only reading, searching and editing files, and running `mix` (also prefixed with `MIX_ENV=test`), `elixir`, `erl`, `git`, `openspec validate`, `chmod` and the project's checks script. Pushing with git MUST be denied.

#### Scenario: Agent permissions
- **WHEN** a task is run
- **THEN** the agent is started with exactly those allowed tools and with `git push` denied

## ADDED Requirements

### Requirement: Keep the agent's verification short
The prompt SHALL tell the agent to run the project's checks script once when its work is complete and again only after fixing a failure, to run only the tests it touched while working, and not to run other full-suite commands in its place, because the gate runs the checks and the OpenSpec validation afterwards. It MUST also tell the agent not to retry or work around a command that was denied, and to report it instead.

#### Scenario: Prompt limits check runs
- **WHEN** a task is run
- **THEN** the agent's prompt tells it to run the checks script once at the end, and again only after fixing a failure, and that the gate runs the checks and the OpenSpec validation

#### Scenario: Prompt says not to retry denied commands
- **WHEN** a task is run
- **THEN** the agent's prompt tells it not to retry or work around a denied command and to report it

### Requirement: Choose the agent's model
The terminal command SHALL accept a `--model NAME` option and start the agent with that model on every attempt of the task. Without the option the agent MUST be started without a model argument.

#### Scenario: Model passed to the agent
- **WHEN** a task is run with `--model sonnet` and its first attempt fails the gate
- **THEN** both attempts start the agent with `--model sonnet`

#### Scenario: No model by default
- **WHEN** a task is run without `--model`
- **THEN** the agent is started without a `--model` argument
