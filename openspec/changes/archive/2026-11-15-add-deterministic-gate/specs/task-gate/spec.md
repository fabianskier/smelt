# Spec Delta

## Purpose

Decides deterministically, without AI, whether the changes in a task's workspace are acceptable, using rules and configuration taken from the task's base commit, so an agent's work is checked before a human is asked to approve it.

## ADDED Requirements

### Requirement: Report a result per rule
The system SHALL evaluate a task workspace against the gate's rules and report an overall result of pass or fail, plus each rule's outcome (pass, fail or skipped) with details explaining it. The overall result MUST be fail when any rule fails, and pass otherwise. The gate MUST only report: it never changes, commits or retries the task's work.

#### Scenario: Every rule passes
- **WHEN** the gate runs on a workspace whose changes satisfy every rule
- **THEN** the overall result is pass and every rule reports pass or skipped

#### Scenario: One rule fails
- **WHEN** the gate runs on a workspace whose changes break one rule
- **THEN** the overall result is fail, that rule reports fail with details, and the other rules report their own outcomes

### Requirement: Measure changes against the base commit
The system SHALL measure a workspace's changes as the difference between the workspace's current files and its base commit, including committed, uncommitted and untracked files, and excluding files the project ignores. Measuring MUST NOT change the workspace's branch, index or files.

#### Scenario: Uncommitted and untracked work is measured
- **WHEN** a workspace has one committed change, one uncommitted change and one new untracked file
- **THEN** the gate counts all three files as changed

#### Scenario: Ignored files are not measured
- **WHEN** a workspace has new files only in paths the project ignores, such as build output
- **THEN** the gate counts no changed files

#### Scenario: The workspace is left as it was
- **WHEN** the gate runs on a workspace with staged, unstaged and untracked changes
- **THEN** the workspace's branch, commit and status are the same as before the gate ran

### Requirement: Protect existing tests and gate configuration
The system SHALL fail the protected-files rule when the workspace modifies, deletes or renames a file that existed at the base commit under one of the project's test paths, or changes any file under `.smelt/`. Adding new files under the test paths MUST be allowed. The failure details MUST list each violating path and how it was changed.

#### Scenario: An existing test is modified
- **WHEN** a workspace modifies a test file that existed at the base commit
- **THEN** the protected-files rule fails and lists that file as modified

#### Scenario: An existing test is deleted
- **WHEN** a workspace deletes a test file that existed at the base commit
- **THEN** the protected-files rule fails and lists that file as deleted

#### Scenario: A new test is added
- **WHEN** a workspace adds a new test file and changes no existing test
- **THEN** the protected-files rule passes

#### Scenario: Gate configuration is changed
- **WHEN** a workspace modifies `.smelt/checks.sh`
- **THEN** the protected-files rule fails and lists `.smelt/checks.sh` as modified

### Requirement: Limit the size of a change
The system SHALL fail the diff-size rule when the number of changed lines (added plus deleted) or the number of changed files exceeds the project's maximum. The details MUST report the measured counts and the maximums.

#### Scenario: Too many changed lines
- **WHEN** a workspace's changes add more lines than the maximum allows
- **THEN** the diff-size rule fails and reports the changed line count and the maximum

#### Scenario: Too many changed files
- **WHEN** a workspace's changes touch more files than the maximum allows
- **THEN** the diff-size rule fails and reports the changed file count and the maximum

### Requirement: Validate OpenSpec artifacts
The system SHALL run strict OpenSpec validation of all changes and specs in the workspace when the workspace has an `openspec/` directory, and fail the OpenSpec rule when validation fails, including the validator's output. Without an `openspec/` directory, the rule MUST be skipped.

#### Scenario: Invalid OpenSpec artifacts
- **WHEN** a workspace contains an OpenSpec spec that fails strict validation
- **THEN** the OpenSpec rule fails and its details include the validator's output

#### Scenario: Project without OpenSpec
- **WHEN** a workspace has no `openspec/` directory
- **THEN** the OpenSpec rule is skipped

### Requirement: Run the project's checks from the base commit
The system SHALL run the project's `.smelt/checks.sh`, as it was at the base commit, with the workspace as its working directory, and fail the checks rule when it exits with a non-zero status. Changes to the script in the workspace MUST have no effect. The details MUST include the exit status and the script's output.

#### Scenario: Checks pass
- **WHEN** the base commit's checks script exits with status 0 in the workspace
- **THEN** the checks rule passes

#### Scenario: Checks fail
- **WHEN** the base commit's checks script exits with a non-zero status
- **THEN** the checks rule fails and its details include the exit status and the script's output

#### Scenario: The workspace's copy of the script is ignored
- **WHEN** a workspace replaces a failing checks script with one that always succeeds
- **THEN** the overall result is fail
- **AND** when the checks run for that workspace, they run the base commit's failing script

#### Scenario: No checks script
- **WHEN** the base commit has no `.smelt/checks.sh`
- **THEN** the checks rule fails with a missing-script reason

### Requirement: Stop checks that run too long
The system SHALL stop the checks script and every process it started when it runs longer than the project's timeout, and fail the checks rule with a timeout reason.

#### Scenario: Checks exceed the timeout
- **WHEN** the checks script starts a child process and keeps running past the timeout
- **THEN** the checks rule fails with a timeout reason, and neither the script nor its child process is still running

### Requirement: Skip checks after a cheaper rule fails
The system SHALL skip the project checks when the protected-files, diff-size or OpenSpec rule has already failed, so a change that is already rejected does not spend time running them.

#### Scenario: Protected test modified
- **WHEN** a workspace modifies an existing test
- **THEN** the checks rule is skipped and the checks script does not run

### Requirement: Configure the gate per project
The system SHALL read optional settings from `.smelt/gate.json` at the base commit: test paths, maximum changed lines, maximum changed files and checks timeout. Missing settings MUST use defaults (`test/`, 400 lines, 20 files, 900 seconds). An invalid file MUST make the gate return a configuration error instead of a result.

#### Scenario: Defaults without a configuration file
- **WHEN** the base commit has no `.smelt/gate.json`
- **THEN** the gate uses the default test paths and limits

#### Scenario: Settings from the base commit
- **WHEN** the base commit's `.smelt/gate.json` sets a lower maximum of changed lines, and the workspace raises it
- **THEN** the gate applies the base commit's maximum

#### Scenario: Invalid configuration
- **WHEN** the base commit's `.smelt/gate.json` is not valid JSON or has a setting of the wrong type or an unknown setting
- **THEN** the gate returns a configuration error naming the problem
