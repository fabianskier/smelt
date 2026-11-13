# Design

## Context

Smelt has PubSub (`Smelt.PubSub`) and Oban, but nothing that runs an agent. See `proposal.md` for motivation and `specs/agent-runner/spec.md` for the required behavior.

Observed output of `claude -p "…" --output-format stream-json --verbose` (Claude Code 2.1.322), one JSON object per line:

| `type` | Relevant fields |
|---|---|
| `system` (`subtype: "init"`) | `session_id`, `model`, `cwd`, `tools`, `permissionMode` |
| `assistant` | `message.content[]` blocks: `text` (`text`) or `tool_use` (`id`, `name`, `input`) |
| `user` | `message.content[]` blocks: `tool_result` (`tool_use_id`, `content`, `is_error`) |
| `rate_limit_event` | `rate_limit_info.rateLimitType`, `unifiedWindows.<window>.utilization`, `resetsAt` (unix seconds), `status` |
| `result` | `subtype`, `is_error`, `result`, `total_cost_usd`, `usage`, `num_turns`, `duration_ms`, `session_id` |

The CLI also prints `no stdin data received in 3s` and waits 3 seconds when stdin is open and empty.

## Goals / Non-Goals

**Goals:**
- A provider-agnostic contract the rest of Smelt depends on, with Claude Code as the first implementation.
- Each run is an OTP process that is supervised, can be found by run id, and always cleans up its OS process.
- Exercise the real `Port` code in tests without spending Claude quota.

**Non-Goals:**
- Choosing CLI permission modes, allowed tools or models per stage. Callers pass extra CLI arguments through an option.
- Run timeouts and retries (Oban's job, later).
- Persisting events (stream only; persistence comes with the state machine).

## Decisions

### 1. Contract: a blocking `run/2` plus a run id chosen up front

```elixir
@callback run(prompt :: String.t(), opts :: keyword()) ::
            {:ok, Smelt.Runner.Result.t()} | {:error, Smelt.Runner.Error.t()}
```

Options: `:cwd` (required), `:run_id` (optional, generated if absent), `:args` (extra CLI arguments), `:env` (extra environment variables for the agent process, passed to the port's `env:`; used by tests to drive the fake CLI and in production for settings such as a separate config directory).
`Smelt.Runner` also provides `new_run_id/0`, `topic/1`, `subscribe/1` and `stop/1`. To follow a run, the caller generates the id, subscribes, then calls `run/2`.

- **Why blocking:** callers will be Oban workers, which naturally wait for the work to finish; live progress goes over PubSub.
- **Alternative:** an async `start/2` returning a pid. Rejected for now: it adds a second API with no caller yet, and it can be added later on top of the same process.

### 2. One supervised process per run

Each run is a `GenServer` (`Smelt.Runner.ClaudeCode.Session`) started under a `DynamicSupervisor` (`Smelt.Runner.Supervisor`) and registered by run id in a `Registry` (`Smelt.Runner.Registry`). The session owns the Port, monitors the caller, and replies to the caller with the result.

- **Why not run the Port in the caller process:** if the caller crashes, nothing would kill the OS process. A separate session that monitors the caller can clean up on `:DOWN`.
- **`restart: :temporary`:** a crashed run must not restart and run the agent again on its own. Retrying is a caller or Oban decision.
- The `Registry` is what makes `stop(run_id)` possible from anywhere, for example from the dashboard.

### 3. Port setup

```elixir
Port.open({:spawn_executable, "/bin/sh"}, [
  :binary, :exit_status, {:line, 65_536}, :stderr_to_stdout,
  cd: cwd,
  args: ["-c", ~s(exec "$0" "$@" < /dev/null), executable | cli_args]
])
```

- **`sh -c 'exec "$0" "$@" < /dev/null'`:** an Erlang port cannot close the child's stdin on its own, so the shell redirects it from `/dev/null`. The arguments are passed as positional parameters, never interpolated, so prompts cannot inject shell code. `exec` replaces the shell, so the port's OS pid is the agent itself.
- **`{:line, 65_536}` plus a buffer:** `{:noeol, chunk}` pieces are accumulated until the `{:eol, chunk}` that ends the line, which supports lines of any length.
- **`:stderr_to_stdout`:** a port only captures stdout, so without it the reason for an early failure (for example, not being logged in) would be lost. Lines that are not JSON produce no event, but the session keeps the last 20 of them and attaches them to `{:exit_status, n, output}`.
- **Executable:** from `config :smelt, Smelt.Runner.ClaudeCode, executable: "claude"`, resolved with `System.find_executable/1`. A missing executable is detected before opening the port and returns `:executable_not_found`.
- **CLI arguments:** `["-p", prompt, "--output-format", "stream-json", "--verbose" | extra_args]`.

### 4. Parsing and normalization

Decoding uses Elixir's built-in `JSON` module, so there is no new dependency. A pure module, `Smelt.Runner.ClaudeCode.Parser`, maps one decoded line to zero or more `%Smelt.Runner.Event{type, data}`:

| Claude Code | Event `type` |
|---|---|
| `system`/`init` | `:session_started` |
| `assistant` text block | `:text` |
| `assistant` tool_use block | `:tool_use` |
| `user` tool_result block | `:tool_result` |
| `rate_limit_event` | `:rate_limit` (one per window in `unifiedWindows`) |
| `result` | `:result` |

Unknown types and unknown content blocks produce no event. `parse_line/1` returns `{:error, :invalid_json}` for lines that are not a JSON object, so the session can keep them as plain output (the last 20 lines attached to `{:exit_status, n, output}`). Keeping the parser pure means most of the mapping is tested without processes.

Besides the parsed events, the session itself broadcasts one `:finished` event when the run ends (`data: {:ok, result} | {:error, reason}`), on success, failure or stop. It is the only event subscribers can rely on to know a run is over, since `:result` is missing when the agent crashes or is stopped.

### 5. Result and errors

- `%Smelt.Runner.Result{text, cost_usd, usage, num_turns, duration_ms, session_id}`.
- `usage` keeps four token counts: `input`, `output`, `cache_read`, `cache_creation`.
- Errors are tagged tuples:

| Error | When |
|---|---|
| `{:exit_status, n, output}` | The agent exits with a non-zero status; `output` holds its last 20 non-JSON lines (stderr included) |
| `{:agent_error, result}` | `is_error: true`, or a `result` subtype other than `success` |
| `:no_result` | The agent exits 0 without reporting a result |
| `:executable_not_found` | The executable cannot be found |
| `:stopped` | The run was stopped |
| `{:crashed, reason}` | The session process crashed (a bug in Smelt, not an agent failure). `run/2` catches the exit of its `GenServer.call` instead of propagating it to the caller |

- The session decides on `{:exit_status, n, output}`, after the stream is fully consumed, because the `result` line arrives before the exit.

### 6. Cleanup

The session traps exits. On `stop/1`, on the caller's `:DOWN` or on `terminate/2`:
1. Read `os_pid` from `Port.info(port, :os_pid)`.
2. Send `SIGTERM` with `System.cmd("kill", ["-TERM", pid])`; after a 2-second grace period, send `SIGKILL` if the process is still alive (checked with `kill -0`).
3. Close the port.

The grace period MUST stay below the session's child-spec `shutdown` (default 5 seconds for workers). Otherwise, when the application shuts down, the supervisor kills the session mid-cleanup and the agent is left running.

**Alternative:** a dependency like `MuonTrap` or `erlexec`. Rejected for now: it adds a native dependency, and plain `kill` is enough for a single process.

### 7. Tests with a fake CLI

- `test/support/fake_claude` is a POSIX `sh` script, configured as the executable in `config/test.exs`. Environment variables select its behavior:
  - replay a JSONL fixture;
  - exit with a given status;
  - write a message to stderr;
  - print its working directory;
  - read stdin until EOF first;
  - sleep, to test stop and owner-exit cleanup;
  - emit a 1 MB line;
  - write its own pid (`$$`) to a file given by an environment variable, so cleanup tests can check with `kill -0` that the process is gone without exposing the OS pid in the API.
- `test/support/fixtures/claude/*.jsonl` holds recorded streams, sanitized: no local paths, tool lists or MCP server names.
- The real `claude` is never called in tests.

## Risks / Trade-offs

- **[Child processes of the agent survive]:** killing Claude Code may leave tools it spawned (for example a `bash` running tests) alive. → Acceptable for this change, since the dashboard only runs read-only prompts. Revisit with process groups or `MuonTrap` before builds run in worktrees (stage 2).
- **[stream-json format changes between CLI versions]:** → The parser ignores unknown types instead of failing; fixtures record the version they came from; parser tests break visibly on changes.
- **[`kill` via `System.cmd` depends on the OS]:** → macOS and Linux both provide it; Windows is not a target.
- **[A blocking `run/2` holds the caller for a long time]:** → Intended for Oban workers. Interactive callers use PubSub and `stop/1`.
