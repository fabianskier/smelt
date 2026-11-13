# Tasks

## 1. Contract and data structures

- [x] 1.1 Define `Smelt.Runner.Event` (`type`, `data`) and `Smelt.Runner.Result` (`text`, `cost_usd`, `usage`, `num_turns`, `duration_ms`, `session_id`) structs with typespecs; verify with `mix compile --warnings-as-errors`
- [x] 1.2 Define the `Smelt.Runner` behaviour (`run/2` callback) and helpers `new_run_id/0`, `topic/1`, `subscribe/1`; verify with a test that `subscribe/1` delivers messages broadcast on `topic/1`

## 2. Parser (pure)

- [x] 2.1 Add sanitized fixtures under `test/support/fixtures/claude/`: record `success.jsonl` (init, text, rate limit, result) and `tool_use.jsonl` (a prompt that reads a file, producing tool use + tool result) with the real CLI (two minimal calls), then derive `error_result.jsonl` (`is_error: true`), `no_result.jsonl` and `unknown_and_malformed.jsonl` by hand from them; verify no local paths, tool lists or MCP server names remain (`grep`)
- [x] 2.2 Implement `Smelt.Runner.ClaudeCode.Parser` mapping decoded lines to events and building the `Result` from a `result` line; verify with parser tests covering every event type, tool use/result, rate limit windows, result metrics, and unknown/malformed lines producing no events

## 3. Run process and supervision

- [x] 3.1 Add `Registry` (`Smelt.Runner.Registry`) and `DynamicSupervisor` (`Smelt.Runner.Supervisor`) to the application tree; verify the app boots and `mix test` passes
- [x] 3.2 Add `test/support/fake_claude` (POSIX `sh`, executable) controlled by env vars (fixture replay, exit status, message on stderr, print cwd, read stdin first, sleep, 1 MB line, write own pid to a file) and configure it as the executable in `config/test.exs`; verify by running it by hand with each mode
- [x] 3.3 Implement `Smelt.Runner.ClaudeCode.Session` (GenServer, `restart: :temporary`) and the happy path of `Smelt.Runner.ClaudeCode.run/2` (options `:cwd`, `:run_id`, `:args`, `:env`; resolve executable, start the session under the supervisor, await its deferred reply): opens the port via `sh -c 'exec "$0" "$@" < /dev/null'` in `cwd` with stderr merged into stdout, buffers `:noeol` chunks, keeps the last 20 non-JSON lines, broadcasts each event on the run topic, replies with the result on exit; tests are grouped as `describe "Requirement: <name>"` / `test "Scenario: <name>"`; verify with tests for "Successful run", "Working directory is honored", "Events arrive in order", "Tool activity is reported", "Subscriber receives the run's events", "Runs are isolated", "Result carries metrics", "Rate-limit status is surfaced" and "Subscribers see a successful end"
- [x] 3.4 Implement error handling (`{:exit_status, n, output}`, `{:agent_error, result}`, `:no_result`, `:executable_not_found`, `{:crashed, reason}`), with every error path broadcasting `:finished`; verify with tests for "Non-zero exit", "Agent reports an error result", "No result before exit", "Executable not found" and "Subscribers see a failure", plus a test that a crashing session makes `run/2` return `{:error, {:crashed, _}}` instead of exiting the caller
- [x] 3.5 Harden output handling (`:noeol` buffering, ignored unknown/malformed lines, stdin closed); verify with tests for "Very long line", "Unknown or malformed line" and "Agent that reads input"

## 4. Cleanup

- [x] 4.1 Implement `Smelt.Runner.stop/1` and OS-process termination (SIGTERM, then SIGKILL after a 2-second grace period, below the 5-second `shutdown`) on stop, on the caller's `:DOWN` and in `terminate/2`; verify with tests for "Run is stopped", "Owner exits" and "Subscribers see a stop" that read the fake's pid file and assert the OS process is gone (`kill -0` fails)

## 5. Integration and docs

- [ ] 5.1 Run one real smoke check by hand in `iex -S mix` (`Smelt.Runner.ClaudeCode.run("Reply with exactly: ok", cwd: File.cwd!())`) and confirm events arrive over PubSub and the result has cost and usage; not part of the automated suite
- [ ] 5.2 Update `docs/architecture.md` (Runner section) with the implemented API and the event types; verify `mix precommit` and `openspec validate add-agent-runner --strict` pass

## Workflow follow-up

- Archive the change after review and merge (`openspec archive add-agent-runner`).
- Then start `add-run-stream-view`.
