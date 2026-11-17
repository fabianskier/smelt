# Spec Delta

## MODIFIED Requirements

### Requirement: Fail with a descriptive error
The system SHALL end a run with an error, instead of a successful result, when the agent executable cannot be started, exits with a non-zero status, reports an error result, exits without reporting a result, or stops because a usage limit was reached. The error MUST identify which of these cases occurred. A usage limit MUST be reported as such, with the agent's final result, whatever the exit status.

#### Scenario: Non-zero exit
- **WHEN** the agent process exits with a non-zero status
- **THEN** the run returns an error identifying the exit status and including the agent's last non-JSON output lines, such as its error messages

#### Scenario: Agent reports an error result
- **WHEN** the agent reports a final result marked as an error
- **THEN** the run returns an error that includes the reported result

#### Scenario: No result before exit
- **WHEN** the agent process exits with status 0 without reporting a final result
- **THEN** the run returns an error stating that no result was received

#### Scenario: Executable not found
- **WHEN** a run is started and the configured agent executable does not exist
- **THEN** the run returns an error stating that the executable was not found

#### Scenario: Usage limit reached
- **WHEN** the agent reports a rejected usage limit and an error result, then exits with status 1
- **THEN** the run returns a usage-limit error that includes the reported result and its message
