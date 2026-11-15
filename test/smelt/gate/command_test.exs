defmodule Smelt.Gate.CommandTest do
  use ExUnit.Case, async: true

  alias Smelt.Gate.Command

  @moduletag :tmp_dir

  defp sh(script, tmp_dir, opts \\ []) do
    Command.run("sh", ["-c", script], Keyword.merge([cd: tmp_dir, timeout: 10_000], opts))
  end

  # Waits for the OS processes in `pid_files` to start and returns their pids.
  defp read_pids(tmp_dir, names) do
    wait_until(fn -> Enum.all?(names, &File.exists?(Path.join(tmp_dir, &1 <> ".done"))) end)

    Enum.map(
      names,
      &(tmp_dir |> Path.join(&1) |> File.read!() |> String.trim() |> String.to_integer())
    )
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      fun.() or System.monotonic_time(:millisecond) > deadline or
        receive(after: (20 -> false))
    end)
    |> Enum.find(& &1)

    assert fun.(), "condition not met within #{timeout} ms"
  end

  # Starts a child `sleep`, records both pids, then blocks.
  @tree_script """
  sleep 30 &
  echo $! > child.pid
  echo $$ > parent.pid
  touch child.pid.done parent.pid.done
  echo started
  wait
  """

  test "returns the exit status and the merged output", %{tmp_dir: tmp_dir} do
    assert sh("echo out; echo err >&2; exit 3", tmp_dir) ==
             {:ok, %{exit_status: 3, output: "out\nerr\n"}}

    assert sh("true", tmp_dir) == {:ok, %{exit_status: 0, output: ""}}
  end

  test "runs in the given directory with the given environment", %{tmp_dir: tmp_dir} do
    assert {:ok, %{output: output}} =
             sh(~s(pwd; echo "$GREETING"), tmp_dir, env: [{"GREETING", "hi"}])

    assert output == "#{tmp_dir}\nhi\n"
  end

  test "an environment variable set to false is removed", %{tmp_dir: tmp_dir} do
    assert {:ok, %{output: "unset\n"}} =
             sh(~s(echo "${HOME-unset}"), tmp_dir, env: [{"HOME", false}])
  end

  test "stdin is closed", %{tmp_dir: tmp_dir} do
    assert sh("cat; echo done", tmp_dir, timeout: 2_000) ==
             {:ok, %{exit_status: 0, output: "done\n"}}
  end

  test "keeps only the end of a long output", %{tmp_dir: tmp_dir} do
    assert {:ok, %{output: output}} =
             sh("for i in $(seq 1 200); do echo line$i; done", tmp_dir, max_output: 20)

    assert byte_size(output) == 20
    assert String.ends_with?(output, "line199\nline200\n")
  end

  test "a missing executable is an error", %{tmp_dir: tmp_dir} do
    assert Command.run("no-such-command-xyz", [], cd: tmp_dir, timeout: 1_000) ==
             {:error, :executable_not_found}
  end

  test "a timeout kills the command and the processes it started", %{tmp_dir: tmp_dir} do
    task = Task.async(fn -> sh(@tree_script, tmp_dir, timeout: 1_000) end)
    [parent, child] = read_pids(tmp_dir, ["parent.pid", "child.pid"])
    assert Command.alive?(parent) and Command.alive?(child)

    assert {:error, {:timeout, output}} = Task.await(task, 10_000)
    assert output == "started\n"

    refute Command.alive?(parent)
    refute Command.alive?(child)
  end

  test "a caller that exits mid-run leaves no process behind", %{tmp_dir: tmp_dir} do
    caller = spawn(fn -> sh(@tree_script, tmp_dir, timeout: 60_000) end)
    [parent, child] = read_pids(tmp_dir, ["parent.pid", "child.pid"])

    Process.exit(caller, :kill)

    wait_until(fn -> not Command.alive?(parent) and not Command.alive?(child) end)
  end
end
