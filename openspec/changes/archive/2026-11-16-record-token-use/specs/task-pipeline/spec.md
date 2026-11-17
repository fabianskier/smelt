# Spec Delta

## ADDED Requirements

### Requirement: Report token use
When a task run ends, whatever its outcome, the terminal command SHALL print the run's token use summed over its attempts (input, cache creation, cache read and output tokens), its turns, cost and model, and the agent's tool calls grouped by tool with the number of calls and the size of the output returned to the agent, largest output first.

#### Scenario: Token report printed
- **WHEN** the command runs a task whose agent reports tokens and calls tools
- **THEN** the output shows the four token counts, the turns and the cost, and one line per tool with its calls and output size, the largest output first

#### Scenario: Attempts are summed
- **WHEN** a task takes two attempts
- **THEN** the reported tokens, turns and cost are the sums of both attempts

### Requirement: Keep a usage record
The terminal command SHALL append one JSON line per task run to `usage.jsonl` under the workspaces root, with the time, the repository, the change, the task id, the outcome, the model, the turns, the cost, the token counts and the tool calls. It MUST NOT contain prompts, tool inputs or tool outputs.

#### Scenario: Usage recorded
- **WHEN** the command runs a task
- **THEN** `usage.jsonl` gains one line with that task's change, task id, outcome, turns and cost

#### Scenario: Earlier records are kept
- **WHEN** the command runs two tasks
- **THEN** `usage.jsonl` has one line for each, in order
