defmodule Smelt.Runner.ClaudeCode.Session do
  @moduledoc """
  One process per agent run: owns the port to the Claude Code CLI, broadcasts
  events while it runs, and replies to the caller once the CLI exits.

  Started by `Smelt.Runner.ClaudeCode.run/2` under `Smelt.Runner.Supervisor` and
  registered by run id in `Smelt.Runner.Registry`. It is `:temporary`: a crashed
  run is never restarted, since that would run the agent again.

  The agent's OS process never outlives the run: it is terminated when the run
  is stopped, when the caller (owner) exits, and when the session terminates.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Smelt.Runner
  alias Smelt.Runner.ClaudeCode.Parser
  alias Smelt.Runner.Event

  # Lines longer than this arrive in `:noeol` chunks and are reassembled.
  @line_bytes 65_536
  # Non-JSON lines (stderr included) kept to explain a non-zero exit.
  @output_lines 20
  @output_line_bytes 1_000

  # After SIGTERM, how long the agent gets to exit before SIGKILL. Together with
  # the wait after SIGKILL it must stay below the child spec's `shutdown`
  # (5 seconds by default), or the supervisor would kill the session mid-cleanup.
  @term_grace_ms 2_000
  @kill_wait_ms 1_000

  # Closes stdin (a port cannot do it) and replaces the shell with the agent,
  # so the port's OS pid is the agent itself. Arguments stay positional, never
  # interpolated into the script.
  @wrapper ~s(exec "$0" "$@" < /dev/null)

  ## API

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :run_id)))
  end

  @doc "Name of the session of `run_id` in `Smelt.Runner.Registry`."
  def via(run_id), do: {:via, Registry, {Smelt.Runner.Registry, run_id}}

  @doc "Blocks until the run ends and returns its outcome."
  def await(server), do: GenServer.call(server, :await, :infinity)

  ## Callbacks

  @impl true
  def init(opts) do
    # Turn exit signals (for example a supervisor shutdown) into a call to
    # terminate/2, so the agent is killed instead of orphaned.
    Process.flag(:trap_exit, true)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, @line_bytes},
        cd: Keyword.fetch!(opts, :cwd),
        env: Keyword.get(opts, :env, []),
        args: ["-c", @wrapper, Keyword.fetch!(opts, :executable) | Keyword.get(opts, :args, [])]
      ])

    {:ok,
     %{
       run_id: Keyword.fetch!(opts, :run_id),
       port: port,
       # Monitor, not link: the session must outlive a dead caller to clean up.
       owner_ref: Process.monitor(Keyword.fetch!(opts, :owner)),
       exited?: false,
       buffer: [],
       output: [],
       result: nil,
       outcome: nil,
       from: nil
     }}
  end

  @impl true
  # The run already ended before the caller asked: reply at once.
  def handle_call(:await, _from, %{outcome: outcome} = state) when outcome != nil do
    {:stop, :normal, outcome, state}
  end

  # Deferred reply: keep `from` and answer when the CLI exits.
  def handle_call(:await, from, state), do: {:noreply, %{state | from: from}}

  def handle_call(:stop, _from, %{outcome: nil} = state) do
    case conclude({:error, :stopped}, kill_agent(state)) do
      {:stop, state} -> {:stop, :normal, :ok, state}
      {:wait, state} -> {:reply, :ok, state}
    end
  end

  # The run already ended; nothing left to stop.
  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: [chunk | state.buffer]}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary(Enum.reverse([chunk | state.buffer]))
    {:noreply, handle_line(line, %{state | buffer: []})}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | exited?: true}
    status |> outcome(state) |> conclude(state) |> to_noreply()
  end

  # The owner exited: nobody will await the result, so stop the agent and end.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref, outcome: nil} = state) do
    {_, state} = conclude({:error, :stopped}, kill_agent(state))
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  # With trap_exit, the port's own exit arrives as a message; exit_status already
  # covers it.
  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  @impl true
  # Runs on normal stops, crashes inside callbacks and supervisor shutdowns.
  # (Not on `Process.exit(pid, :kill)`, which cannot be trapped.)
  def terminate(_reason, state) do
    kill_agent(state)
    :ok
  end

  ## Output handling

  defp handle_line(line, state) do
    case Parser.parse_line(line) do
      {:ok, events} ->
        Enum.reduce(events, state, fn event, state ->
          Runner.broadcast(state.run_id, event)
          track_result(event, state)
        end)

      {:error, :invalid_json} ->
        Logger.debug("agent output: #{line}", run_id: state.run_id)
        keep_output(line, state)
    end
  end

  defp track_result(%Event{type: :result, data: data}, state), do: %{state | result: data}
  defp track_result(_event, state), do: state

  defp keep_output(line, state) do
    line = binary_part(line, 0, min(byte_size(line), @output_line_bytes))
    %{state | output: Enum.take([line | state.output], @output_lines)}
  end

  ## Ending a run

  # The `result` line arrives before the exit, but the exit status decides.
  defp outcome(status, state) when status != 0 do
    {:error, {:exit_status, status, Enum.reverse(state.output)}}
  end

  defp outcome(0, %{result: nil}), do: {:error, :no_result}

  defp outcome(0, %{result: %{is_error: false, subtype: "success", result: result}}) do
    {:ok, result}
  end

  defp outcome(0, %{result: %{result: result}}), do: {:error, {:agent_error, result}}

  # Records the outcome and tells subscribers (exactly once). Replies to the
  # caller if it is already waiting; otherwise keeps the outcome for :await.
  defp conclude(outcome, state) do
    Runner.broadcast(state.run_id, %Event{type: :finished, data: outcome})
    state = %{state | outcome: outcome}

    case state.from do
      nil ->
        {:wait, state}

      from ->
        GenServer.reply(from, outcome)
        {:stop, state}
    end
  end

  defp to_noreply({:stop, state}), do: {:stop, :normal, state}
  defp to_noreply({:wait, state}), do: {:noreply, state}

  # SIGTERM, then SIGKILL if the agent is still running after the grace period.
  # Waiting for the port's exit_status also guarantees the process was reaped.
  defp kill_agent(%{exited?: true} = state), do: state

  defp kill_agent(%{port: port} = state) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        signal(os_pid, "TERM")

        unless await_exit(port, @term_grace_ms) do
          signal(os_pid, "KILL")
          await_exit(port, @kill_wait_ms)
        end

      nil ->
        :ok
    end

    %{state | exited?: true}
  end

  defp await_exit(port, timeout) do
    receive do
      {^port, {:exit_status, _status}} -> true
    after
      timeout -> false
    end
  end

  defp signal(os_pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end
end
