# Spec Delta

## ADDED Requirements

### Requirement: Stop on a usage limit
When an agent attempt ends because a usage limit was reached, the system SHALL stop without running the gate and report the outcome as usage limited, distinct from agent failed, keeping the workspace. The terminal command MUST say that the task was stopped by a usage limit and show the agent's message.

#### Scenario: Usage limit stops the task
- **WHEN** the agent of a task reaches a usage limit
- **THEN** the outcome is usage limited, the gate does not run, the workspace still exists, and the command's output says the task was stopped by a usage limit with the agent's message

### Requirement: Count the cost of failed attempts
The cost of a task run SHALL include every attempt that reported a cost, including attempts that ended with an error result or a usage limit.

#### Scenario: Cost of a stopped attempt
- **WHEN** an agent attempt reports a cost of 0.91 USD and then reaches a usage limit
- **THEN** the task run's cost is 0.91 USD
