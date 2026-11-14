# Spec Delta

## Purpose

Gives each task its own isolated git worktree and branch in a target project repository, so an agent can change code for that task without touching the user's checkout or any other task.

## ADDED Requirements

### Requirement: Create a workspace for a task
The system SHALL create a workspace for a task, identified by a project repository, a change name and a task id. It MUST check out a new branch for that task from a base branch (`main` unless another is given) into a directory outside the project repository, and MUST report the workspace's directory, branch and base commit.

#### Scenario: Workspace is created from the base branch
- **WHEN** a workspace is created for a task in a repository whose `main` branch has commits
- **THEN** the result reports a directory outside the repository, a branch named after the change and task, and the commit `main` pointed to
- **AND** the directory contains the files of that commit with the task's branch checked out

#### Scenario: Another base branch is used
- **WHEN** a workspace is created with a base branch other than `main`
- **THEN** the task's branch starts at that branch's current commit

#### Scenario: Base branch does not exist
- **WHEN** a workspace is created with a base branch that the repository does not have
- **THEN** creation fails with an error naming the missing base, and no directory or branch is left behind

#### Scenario: Not a git repository
- **WHEN** a workspace is created for a directory that is not a git repository
- **THEN** creation fails with a not-a-repository error

### Requirement: Leave the user's checkout untouched
Workspace operations MUST NOT change the project repository's checked-out branch, index or working files, including files that are modified or untracked there.

#### Scenario: Checkout with uncommitted work is preserved
- **WHEN** the repository's checkout has modified and untracked files, and a workspace is created and then removed
- **THEN** the checkout is on the same branch with the same modified and untracked files, unchanged

### Requirement: One workspace per task
The system SHALL allow at most one workspace per task in a repository. Creating a workspace for a task that already has one MUST fail without changing the existing workspace.

#### Scenario: Task already has a workspace
- **WHEN** a workspace is created for a task that already has one
- **THEN** creation fails with an already-exists error
- **AND** the existing workspace's directory, branch and files are unchanged

### Requirement: Reject unsafe identifiers
The system MUST reject a change name that is not kebab-case or a task id that is not dot-separated numbers (for example `2.1`), before running any git command.

#### Scenario: Change name with a path separator
- **WHEN** a workspace is created with a change name such as `../escape`
- **THEN** creation fails with an invalid-identifier error and nothing is created on disk or in git

#### Scenario: Malformed task id
- **WHEN** a workspace is created with a task id such as `1..2` or `main`
- **THEN** creation fails with an invalid-identifier error

### Requirement: Look up an existing workspace
The system SHALL return an existing workspace given the same repository, change name and task id used to create it, so a pipeline can resume a task after a crash or restart.

#### Scenario: Workspace is found again
- **WHEN** a workspace is looked up after it was created
- **THEN** the lookup reports the same directory, branch and base commit that creation reported

#### Scenario: Workspace does not exist
- **WHEN** a workspace is looked up for a task that has none
- **THEN** the lookup fails with a not-found error

### Requirement: List managed workspaces
The system SHALL list the workspaces it manages in a repository, and MUST NOT include worktrees or branches it did not create.

#### Scenario: Only managed workspaces are listed
- **WHEN** a repository has two Smelt workspaces and one worktree the user created by hand
- **THEN** listing returns exactly the two Smelt workspaces

### Requirement: Remove a workspace
The system SHALL remove a workspace's directory and its branch, including uncommitted and untracked files in the workspace. When the branch has commits that are not in the base branch, the system MUST keep the branch unless removal is forced, and MUST say that it kept it. Removing a workspace that does not exist MUST succeed.

#### Scenario: Workspace without new commits is removed
- **WHEN** a workspace whose branch has no commits beyond the base is removed
- **THEN** its directory and its branch no longer exist, and it is no longer listed

#### Scenario: Unmerged branch is kept
- **WHEN** a workspace whose branch has commits that are not in the base is removed without forcing
- **THEN** its directory no longer exists, its branch still exists, and the result says the branch was kept

#### Scenario: Forced removal deletes an unmerged branch
- **WHEN** a workspace whose branch has commits that are not in the base is removed with force
- **THEN** its directory and its branch no longer exist

#### Scenario: Removing a missing workspace
- **WHEN** a workspace that does not exist is removed
- **THEN** removal succeeds and changes nothing

### Requirement: Concurrent operations are safe
The system SHALL allow workspace operations for different tasks in the same repository to run concurrently, and each MUST succeed or fail as if it ran alone.

#### Scenario: Concurrent creation for different tasks
- **WHEN** workspaces for several different tasks of the same repository are created at the same time
- **THEN** every creation succeeds, and each workspace has its own directory and branch
