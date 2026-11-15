# Spec Delta

## MODIFIED Requirements

### Requirement: Instruct the agent
The system SHALL give the agent a prompt that names the change, the task id and the task's description, points to the change's artifacts, and tells it to implement only that task, mark its checkbox, run the project's checks, and commit its work. The prompt MUST also tell it to put new tests in new test files, because adding to an existing test file counts as modifying it.

#### Scenario: Prompt describes the task
- **WHEN** a task is run
- **THEN** the agent's prompt contains the change name, the task id, the task's description and the path of the change's `tasks.md`

#### Scenario: Prompt says where new tests go
- **WHEN** a task is run
- **THEN** the agent's prompt tells it to put new tests in new test files and that adding to an existing test file counts as modifying it
