# Spec Delta

## ADDED Requirements

### Requirement: Prepare the workspace before the agent
When the task's base commit has a `.smelt/setup.sh`, the system SHALL run that script in the new workspace before starting the agent, within a time limit, and report its start and its outcome as events. The script's output MUST NOT be given to the agent. A script that fails or runs out of time MUST NOT stop the task. Without the script the system MUST start the agent directly and send no setup events.

#### Scenario: Setup runs before the agent
- **WHEN** a task is run in a project whose base commit has a setup script that writes a file
- **THEN** the file exists in the workspace when the agent starts, and a subscriber receives setup started and setup finished before agent started

#### Scenario: Failed setup does not stop the task
- **WHEN** the setup script exits with a non-zero status
- **THEN** the setup is reported as failed with its output, and the agent still runs

#### Scenario: No setup script
- **WHEN** a task is run in a project without a setup script
- **THEN** no setup event is sent

### Requirement: Cap the agent's spending
The system SHALL start every agent attempt with a spending limit in USD, 5 by default, and the terminal command SHALL accept `--max-budget USD` to change it. A run that the agent ends because the limit was reached MUST be reported as a failed agent, keeping the workspace.

#### Scenario: Default budget
- **WHEN** a task is run without a budget option
- **THEN** the agent is started with a spending limit of 5 USD

#### Scenario: Budget from the command line
- **WHEN** a task is run with `--max-budget 1.5` and its first attempt fails the gate
- **THEN** both attempts start the agent with a spending limit of 1.5 USD
