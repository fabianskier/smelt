defmodule Smelt.Gate.Command do
  @moduledoc """
  Runs an external command for the gate, with a timeout, and never leaves
  its processes behind.

  A dedicated process owns the port and collects the output, while the
  caller blocks waiting for its reply. The command's whole process tree (for
  example `sh` → `mix test` → BEAM) is killed when the timeout expires or the
  caller exits: SIGTERM first, then SIGKILL for anything still alive after a
  grace period.

  Erlang ports can't put a command in its own process group, so the tree is
  found with `ps`. A process that double-forks away from the tree (a daemon)
  is not found; test runners don't do that.
  """

  @max_output 65_536
  @term_grace_ms 2_000
  @poll_ms 50

  # Closes stdin (a port can't) and replaces the shell with the command, so
  # the port's OS pid is the command itself. Arguments stay positional.
  @wrapper ~s(exec "$0" "$@" < /dev/null)

  @type result :: %{exit_status: non_neg_integer(), output: String.t()}

  @doc """
  Runs `executable` with `args` and waits for it to exit.

  Options:

    * `:cd` - working directory (required)
    * `:timeout` - milliseconds before the command is killed (required)
    * `:env` - extra environment variables, as `[{"NAME", "value"}]`
    * `:max_output` - bytes of output kept, from the end, default 64 KiB

  Stderr is merged into the output. Returns `{:ok, %{exit_status:, output:}}`
  when the command exits on its own (whatever its status),
  `{:error, {:timeout, output}}` when it was killed, or
  `{:error, :executable_not_found}`.
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, result()} | {:error, {:timeout, String.t()} | :executable_not_found}
  def run(executable, args, opts) do
    case System.find_executable(executable) do
      nil ->
        {:error, :executable_not_found}

      path ->
        caller = self()
        ref = make_ref()
        {_pid, monitor} = spawn_monitor(fn -> owner(caller, ref, path, args, opts) end)

        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, :process, _pid, reason} ->
            exit({:command_owner_crashed, reason})
        end
    end
  end

  ## Owner process

  defp owner(caller, ref, executable, args, opts) do
    caller_monitor = Process.monitor(caller)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: Keyword.fetch!(opts, :cd),
        env: for({name, value} <- Keyword.get(opts, :env, []), do: {~c"#{name}", ~c"#{value}"}),
        args: ["-c", @wrapper, executable | args]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    timer = Process.send_after(self(), :timeout, Keyword.fetch!(opts, :timeout))

    state = %{
      port: port,
      os_pid: os_pid,
      output: <<>>,
      max_output: Keyword.get(opts, :max_output, @max_output)
    }

    case collect(state, caller_monitor) do
      {:exit, status, output} ->
        Process.cancel_timer(timer)
        send(caller, {ref, {:ok, %{exit_status: status, output: output}}})

      {:timeout, output} ->
        send(caller, {ref, {:error, {:timeout, output}}})

      :caller_down ->
        :ok
    end
  end

  defp collect(%{port: port} = state, caller_monitor) do
    receive do
      {^port, {:data, data}} ->
        collect(
          %{state | output: keep_tail(state.output <> data, state.max_output)},
          caller_monitor
        )

      {^port, {:exit_status, status}} ->
        {:exit, status, state.output}

      :timeout ->
        kill_tree(state.os_pid)
        {:timeout, drain(state)}

      {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
        kill_tree(state.os_pid)
        :caller_down
    end
  end

  # Collects what the command printed before it died, without waiting long.
  defp drain(%{port: port} = state) do
    receive do
      {^port, {:data, data}} ->
        drain(%{state | output: keep_tail(state.output <> data, state.max_output)})

      {^port, {:exit_status, _status}} ->
        state.output
    after
      @term_grace_ms -> state.output
    end
  end

  defp keep_tail(output, max) when byte_size(output) <= max, do: output
  defp keep_tail(output, max), do: binary_part(output, byte_size(output) - max, max)

  ## Process tree

  @doc false
  # Kills `os_pid` and all of its descendants: SIGTERM, then SIGKILL for any
  # still alive after the grace period. The tree is read before signalling,
  # because children are re-parented as soon as their parent dies.
  def kill_tree(os_pid) do
    pids = [os_pid | descendants(os_pid)]
    signal(pids, "TERM")

    deadline = System.monotonic_time(:millisecond) + @term_grace_ms

    case wait_dead(pids, deadline) do
      [] -> :ok
      alive -> signal(alive, "KILL")
    end
  end

  defp descendants(os_pid) do
    {output, 0} = System.cmd("ps", ["-A", "-o", "pid=", "-o", "ppid="])

    children =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.split() |> Enum.map(fn n -> String.to_integer(n) end)))
      |> Enum.group_by(fn [_pid, ppid] -> ppid end, fn [pid, _ppid] -> pid end)

    collect_descendants([os_pid], children, [])
  end

  defp collect_descendants([], _children, acc), do: acc

  defp collect_descendants([pid | rest], children, acc) do
    kids = Map.get(children, pid, [])
    collect_descendants(kids ++ rest, children, acc ++ kids)
  end

  defp wait_dead(pids, deadline) do
    case Enum.filter(pids, &alive?/1) do
      [] ->
        []

      alive ->
        if System.monotonic_time(:millisecond) >= deadline do
          alive
        else
          receive after: (@poll_ms -> wait_dead(alive, deadline))
        end
    end
  end

  @doc false
  # A zombie (exited, not yet reaped) counts as dead.
  def alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)]) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_, _} -> false
    end
  end

  defp signal(pids, signal) do
    System.cmd("kill", ["-#{signal}" | Enum.map(pids, &Integer.to_string/1)],
      stderr_to_stdout: true
    )
  end
end
