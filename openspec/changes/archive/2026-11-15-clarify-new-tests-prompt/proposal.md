# Proposal

## Why

The gate fails a task that changes an existing test file in any way, including adding new tests to it. That rule stays: "only added lines" can still disable a test (an added `@tag :skip`, or an `if false do … end` around its body), and comparing tests by name would tie the gate to one test framework. But the agent's prompt only says "do not modify existing tests", which reads as allowing additions: in `viborita` task 2.1 the agent added its tests to the existing file, failed the gate, and needed a retry (about $0.53) to move them to a new file.

## What Changes

- The task prompt tells the agent to put new tests in new test files, because adding to an existing test file counts as modifying it and fails the gate.
- The gate's protected-files rule is unchanged.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `task-pipeline`: the "Instruct the agent" requirement also tells the agent where new tests go.

## Impact

- `Smelt.TaskRun.Prompt.task/2`. One new test file; no existing test changes.
