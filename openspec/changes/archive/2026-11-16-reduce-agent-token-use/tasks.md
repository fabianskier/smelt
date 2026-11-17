# Tasks

## 1. Permissions

- [x] 1.1 Add `Bash(openspec validate:*)` and `Bash(chmod:*)` to `Smelt.TaskRun`'s agent arguments (after `Bash(git:*)`), and update the "Agent permissions" test in `test/smelt/task_run_test.exs` to the new list (the proposal allows this one test change); verify with `mix test test/smelt/task_run_test.exs` and update the permissions line of the `Smelt.TaskRun` entry in `docs/architecture.md`

## 2. Prompt

- [x] 2.1 Replace the checks rule of `Smelt.TaskRun.Prompt.task/2` with the rules of the "Keep the agent's verification short" requirement (checks once at the end and again only after fixing a failure, only the touched tests while working, no other full-suite commands because the gate runs the checks and the OpenSpec validation, never retry or work around a denied command but report it), keeping the text `sh .smelt/checks.sh`; verify with a new `test/smelt/task_run/prompt_verification_test.exs`: "Scenario: Prompt limits check runs" and "Scenario: Prompt says not to retry denied commands", and that the existing prompt tests pass unchanged

## 3. Model option

- [x] 3.1 Add a `:model` option to `Smelt.TaskRun.run/4` that appends `--model NAME` to the agent arguments of every attempt, and a `--model` switch to `mix smelt.task` that passes it (documented in the task's moduledoc); verify with a new `test/smelt/task_run_model_test.exs`: "Scenario: Model passed to the agent" and "Scenario: No model by default"
- [x] 3.2 Document the option and the prompt's rules in `docs/architecture.md`, record the change in `docs/roadmap.md`, and verify `mix precommit` and `openspec validate reduce-agent-token-use --strict`

## Workflow follow-up

- Archive the change after review (`openspec archive reduce-agent-token-use`).
- On the next `courier` task, compare turns and cost with the 2026-11-16 runs.
