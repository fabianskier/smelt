# task-pipeline Specification

## Purpose
Runs one task of an OpenSpec change end to end: an agent implements it in the task's workspace, the gate checks it with one retry, and the user approves it to merge it into the base branch or discards it, with progress reported as events.

## Requirements

### Requirement: Run a task end to end
The system SHALL run a task given a project repository, a change name and a task id: create the task's workspace, run the agent on the task in it, run the gate, and report the outcome (passed, gate failed or agent failed) with the gate result and the agent's total cost. The workspace MUST be kept after the run, whatever the outcome.

#### Scenario: Task passes the gate
- **WHEN** a task is run and the agent's work passes the gate
- **THEN** the outcome is passed, it includes the gate result and the cost, and the workspace still exists

### Requirement: Read the task from the base commit
The system SHALL take the task's description from the change's `tasks.md` as it is at the workspace's base commit. An unknown change or task id, or a task already marked done, MUST fail before the agent runs, leaving no workspace behind.

#### Scenario: Unknown task
- **WHEN** a task is run with a task id that is not in the change's `tasks.md`
- **THEN** the run fails with a task-not-found error, the agent does not run, and no workspace exists for the task

#### Scenario: Task already done
- **WHEN** a task is run whose checkbox is already marked done
- **THEN** the run fails with a task-done error and no workspace exists for the task

### Requirement: Instruct the agent
The system SHALL give the agent a prompt that names the change, the task id and the task's description, points to the change's artifacts, and tells it to implement only that task, mark its checkbox, run the project's checks, and commit its work. The prompt MUST also tell it to put new tests in new test files, because adding to an existing test file counts as modifying it.

#### Scenario: Prompt describes the task
- **WHEN** a task is run
- **THEN** the agent's prompt contains the change name, the task id, the task's description and the path of the change's `tasks.md`

#### Scenario: Prompt says where new tests go
- **WHEN** a task is run
- **THEN** the agent's prompt tells it to put new tests in new test files and that adding to an existing test file counts as modifying it

### Requirement: Limit the agent's permissions
The system SHALL run the agent allowing only reading, searching and editing files, and running `mix` (also prefixed with `MIX_ENV=test`), `elixir`, `erl`, `git`, `openspec validate`, `chmod` and the project's checks script. Pushing with git MUST be denied.

#### Scenario: Agent permissions
- **WHEN** a task is run
- **THEN** the agent is started with exactly those allowed tools and with `git push` denied

### Requirement: Retry once after a failed gate
The system SHALL, when the gate fails, resume the same agent session once with a message describing each failed rule, then run the gate again. If the gate fails again, the outcome MUST be gate failed.

#### Scenario: Fixed on retry
- **WHEN** the agent's first attempt fails the gate and its resumed attempt passes it
- **THEN** the outcome is passed after two attempts, and the second attempt resumed the first one's session with the gate's findings

#### Scenario: Fails twice
- **WHEN** both attempts fail the gate
- **THEN** the outcome is gate failed after two attempts, with the last gate result

### Requirement: Stop when the agent fails
The system SHALL stop without running the gate when the agent run ends with an error, and report the outcome as agent failed with the error.

#### Scenario: Agent fails
- **WHEN** the agent exits with an error
- **THEN** the outcome is agent failed, the gate does not run, and the workspace still exists

### Requirement: Merge an approved task
The system SHALL merge an approved task by committing any uncommitted changes in its workspace, fast-forwarding the base branch to the task's branch, and removing the workspace and its branch. When the base branch is checked out in a worktree, that checkout's files MUST be updated as well.

#### Scenario: Approved task is merged
- **WHEN** a passed task is approved while the user's checkout is on the base branch with no changes
- **THEN** the base branch points to the task's work, the checkout's files contain it, and the workspace and its branch no longer exist

#### Scenario: Base branch not checked out
- **WHEN** a passed task is approved while no worktree has the base branch checked out
- **THEN** the base branch points to the task's work

#### Scenario: Uncommitted work is committed on merge
- **WHEN** a passed task whose workspace has uncommitted changes is approved
- **THEN** those changes are part of the merged work

### Requirement: Rebase and gate again when the base moved
The system SHALL, when the base branch has new commits since the workspace was created, rebase the task's branch onto it and run the gate again against the new base before merging. A rebase conflict or a failing gate MUST stop the merge, leaving the base branch unchanged and keeping the workspace.

#### Scenario: Base moved without conflicts
- **WHEN** a passed task is approved after the base branch got an unrelated commit
- **THEN** the base branch contains both the unrelated commit and the task's work

#### Scenario: Rebase conflict
- **WHEN** a passed task is approved after the base branch got a commit that conflicts with the task's work
- **THEN** the merge fails with a rebase-conflict error, the base branch is unchanged, and the workspace still exists

### Requirement: Never overwrite the user's uncommitted work
The system SHALL refuse to merge when the base branch is checked out in a worktree that has uncommitted changes to tracked files, leaving everything unchanged.

#### Scenario: Checkout with uncommitted changes
- **WHEN** a passed task is approved while the user's checkout is on the base branch with a modified tracked file
- **THEN** the merge fails with a dirty-checkout error, and the base branch, the modified file and the workspace are unchanged

### Requirement: Discard a task
The system SHALL discard a task by removing its workspace and its branch, whatever its outcome.

#### Scenario: Task discarded
- **WHEN** a task that failed the gate is discarded
- **THEN** its workspace and its branch no longer exist

### Requirement: Report progress as events
The system SHALL broadcast each step of a task run over PubSub on a topic unique to that run: workspace created, each agent attempt started and finished, each gate run started and finished, and the final outcome. The run identifier and the identifiers of the agent runs MUST be known before the run starts, so subscribers miss no event.

#### Scenario: Progress events in order
- **WHEN** a subscriber follows a task that passes on its first attempt
- **THEN** it receives, in order: workspace created, agent started, agent finished, gate started, gate finished, finished

### Requirement: Drive a task from the terminal
The system SHALL provide a terminal command that runs a task, shows the agent's activity and the gate result as they happen, and then asks for approval: yes merges the task, anything else keeps the workspace for later. A discard option MUST remove a task's workspace without running it.

#### Scenario: Approve from the terminal
- **WHEN** the command runs a task that passes and the user answers yes
- **THEN** the task is merged and the command reports the merge

#### Scenario: Decline keeps the workspace
- **WHEN** the command runs a task that passes and the user answers no
- **THEN** nothing is merged and the workspace still exists

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
