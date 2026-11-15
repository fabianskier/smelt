defmodule Smelt.Runner.ClaudeCode do
  @moduledoc """
  `Smelt.Runner` implementation for the Claude Code CLI in headless mode:

      claude -p <prompt> --output-format stream-json --verbose [args]

  The CLI is configured with:

      config :smelt, Smelt.Runner.ClaudeCode, executable: "claude"

  Each run is a `Smelt.Runner.ClaudeCode.Session` process; see `Smelt.Runner`
  for how to follow its events.

  Every run is isolated from whoever launched Smelt: it loads only the
  working directory's project and local settings (`--setting-sources
  project,local`), and its environment has no variables from a parent
  Claude Code session or terminal integration (see `isolated_env/1`).
  """

  @behaviour Smelt.Runner

  # Load only the working directory's project and local settings, never the
  # user's own (hooks, plugins, skills, MCP servers). Login is unaffected.
  @isolation_args ["--setting-sources", "project,local"]

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
          owner: self(),
          cwd: cwd,
          executable: executable,
          args: [
            "-p",
            prompt,
            "--output-format",
            "stream-json",
            "--verbose" | @isolation_args ++ Keyword.get(opts, :args, [])
          ],
          # Unset first, so a variable the caller passes explicitly wins.
          env: to_port_env(isolated_env(System.get_env()) ++ Keyword.get(opts, :env, []))
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

  @doc """
  Returns the variables to remove from the agent's environment, as
  `{name, false}`, given Smelt's own environment as a map.

  They belong to a parent Claude Code session (`CLAUDECODE`, `CLAUDE_*`,
  `AI_AGENT`) or to a terminal integration (`REX_*`): an agent that inherits
  them may act on the session that launched Smelt instead of on its task.

      iex> Smelt.Runner.ClaudeCode.isolated_env(%{"CLAUDECODE" => "1", "PATH" => "/bin"})
      [{"CLAUDECODE", false}]
  """
  @spec isolated_env(%{String.t() => String.t()}) :: [{String.t(), false}]
  def isolated_env(env) do
    for {name, _value} <- env, inherited_from_session?(name), do: {name, false}
  end

  defp inherited_from_session?(name) do
    name in ["CLAUDECODE", "AI_AGENT"] or String.starts_with?(name, ["CLAUDE_", "REX_"])
  end

  # `false` removes a variable from the inherited environment.
  defp to_port_env(env) do
    Enum.map(env, fn
      {key, false} -> {to_charlist(key), false}
      {key, value} -> {to_charlist(key), to_charlist(value)}
    end)
  end
end
