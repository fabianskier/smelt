# Spec Delta

## Purpose

Runs a coding agent with a prompt in a working directory, streams its activity as provider-independent events while it works, and reports a final result with cost and usage, so every Smelt stage can delegate work to an agent and observe it live.

## ADDED Requirements

### Requirement: Run an agent with a prompt
The system SHALL run a coding agent given a prompt and a working directory, and SHALL return a final result once the agent finishes. The agent process MUST run with the given working directory as its current directory.

#### Scenario: Successful run
- **WHEN** a run is started with a prompt and an existing working directory, and the agent completes successfully
- **THEN** the run returns a successful result containing the agent's final text

#### Scenario: Working directory is honored
- **WHEN** a run is started with a working directory
- **THEN** the agent process reports that directory as its current directory

### Requirement: Stream normalized events
The system SHALL emit an event for each activity the agent reports, in the order the agent reports them, while the run is in progress. Events MUST use a provider-independent shape with one of the types: session started, assistant text, tool use, tool result, rate limit, final result.

#### Scenario: Events arrive in order
- **WHEN** the agent reports session start, assistant text, a rate-limit status and a final result
- **THEN** the run emits session started, assistant text, rate limit and final result events in that order

#### Scenario: Tool activity is reported
- **WHEN** the agent reports a tool call and its result
- **THEN** the run emits a tool use event with the tool name and input, followed by a tool result event

### Requirement: Broadcast events per run
The system SHALL broadcast every event of a run over PubSub on a topic unique to that run, so that any number of subscribers can follow it. The run identifier MUST be available to the caller before the first event is broadcast.

#### Scenario: Subscriber receives the run's events
- **WHEN** a process subscribes to a run's topic before the run starts emitting
- **THEN** it receives every event of that run, in order

#### Scenario: Runs are isolated
- **WHEN** two runs execute and a process subscribes only to the first run's topic
- **THEN** it receives no events from the second run

### Requirement: Notify subscribers when a run ends
The system SHALL broadcast exactly one final event on the run's topic when a run ends, whether it succeeds, fails or is stopped. The event MUST carry the same outcome returned to the caller: the result on success, or the error otherwise. No events MUST be broadcast for that run after it.

#### Scenario: Subscribers see a successful end
- **WHEN** a subscribed run completes successfully
- **THEN** subscribers receive one final event carrying the result, after all other events of the run

#### Scenario: Subscribers see a failure
- **WHEN** a subscribed run's agent process exits with a non-zero status
- **THEN** subscribers receive one final event carrying the same error the caller receives

#### Scenario: Subscribers see a stop
- **WHEN** a subscribed run is stopped
- **THEN** subscribers receive one final event carrying the stopped error

### Requirement: Report cost and usage in the result
The final result SHALL include the agent's final text, the cost in USD, the token usage (input, output, cache read and cache creation tokens), the number of turns, the duration and the agent's session identifier.

#### Scenario: Result carries metrics
- **WHEN** a run completes and the agent reports cost, usage, turns, duration and session id
- **THEN** the returned result contains all of those values

### Requirement: Report usage-limit status
The system SHALL emit a rate-limit event whenever the agent reports its usage-limit status, including the limit window, its utilization and when it resets, so that later components can pause work before the limit is reached.

#### Scenario: Rate-limit status is surfaced
- **WHEN** the agent reports a five-hour window at 13% utilization with a reset time
- **THEN** the run emits a rate-limit event with that window, utilization and reset time

### Requirement: Tolerate unknown and long output
The system SHALL parse agent output lines of any length. Lines that are not valid JSON, or that have an unrecognized type, MUST NOT fail the run.

#### Scenario: Very long line
- **WHEN** the agent emits a single event line larger than 1 MB
- **THEN** the run emits the corresponding event with its full content

#### Scenario: Unknown or malformed line
- **WHEN** the agent emits a line with an unrecognized event type or a line that is not valid JSON
- **THEN** the run continues and still returns the final result

### Requirement: Fail with a descriptive error
The system SHALL end a run with an error, instead of a successful result, when the agent executable cannot be started, exits with a non-zero status, reports an error result, or exits without reporting a result. The error MUST identify which of these cases occurred.

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

### Requirement: Agent does not wait for input
The system SHALL start the agent with its standard input closed, so the agent never blocks waiting for input.

#### Scenario: Agent that reads input
- **WHEN** the agent reads its standard input until end of file before producing output
- **THEN** the run completes without waiting for input

### Requirement: Clean up the agent process
The system SHALL terminate the agent's operating-system process when a run is stopped or when the process that owns the run exits, so no agent keeps running unobserved.

#### Scenario: Run is stopped
- **WHEN** a running run is stopped
- **THEN** the agent's operating-system process is no longer running and the run reports that it was stopped

#### Scenario: Owner exits
- **WHEN** the process that started a run exits while the agent is still running
- **THEN** the agent's operating-system process is no longer running
