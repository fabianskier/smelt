defmodule Smelt.Runner.ClaudeCode do
  @moduledoc """
  `Smelt.Runner` implementation for the Claude Code CLI in headless mode:

      claude -p <prompt> --output-format stream-json --verbose [args]

  The CLI is configured with:

      config :smelt, Smelt.Runner.ClaudeCode, executable: "claude"

  Each run is a `Smelt.Runner.ClaudeCode.Session` process; see `Smelt.Runner`
  for how to follow its events.
  """

  @behaviour Smelt.Runner

  alias Smelt.Runner
  alias Smelt.Runner.ClaudeCode.Session
  alias Smelt.Runner.Event

  @doc """
  Runs Claude Code with `prompt` and blocks until it finishes.

  Options, besides those of `c:Smelt.Runner.run/2`:

    * `:executable` - overrides the configured executable
  """
  @impl Runner
  def run(prompt, opts) when is_binary(prompt) do
    cwd = Keyword.fetch!(opts, :cwd)
    run_id = Keyword.get_lazy(opts, :run_id, &Runner.new_run_id/0)

    unless File.dir?(cwd) do
      raise ArgumentError, "working directory does not exist: #{inspect(cwd)}"
    end

    case System.find_executable(Keyword.get_lazy(opts, :executable, &configured_executable/0)) do
      nil ->
        fail(run_id, :executable_not_found)

      executable ->
        session_opts = [
          run_id: run_id,
          cwd: cwd,
          executable: executable,
          args: [
            "-p",
            prompt,
            "--output-format",
            "stream-json",
            "--verbose" | Keyword.get(opts, :args, [])
          ],
          env: opts |> Keyword.get(:env, []) |> to_port_env()
        ]

        case DynamicSupervisor.start_child(Smelt.Runner.Supervisor, {Session, session_opts}) do
          {:ok, pid} -> await(pid, run_id)
          {:error, reason} -> fail(run_id, {:crashed, reason})
        end
    end
  end

  # If the session crashes, `GenServer.call` exits the caller; turn that into an
  # error so a bug in Smelt does not take the caller (for example an Oban job) down.
  defp await(pid, run_id) do
    Session.await(pid)
  catch
    :exit, {reason, {GenServer, :call, _}} -> fail(run_id, {:crashed, reason})
  end

  # Errors raised before or instead of the session still notify subscribers.
  defp fail(run_id, reason) do
    error = {:error, reason}
    Runner.broadcast(run_id, %Event{type: :finished, data: error})
    error
  end

  defp configured_executable do
    :smelt |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:executable)
  end

  defp to_port_env(env) do
    Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end
end
