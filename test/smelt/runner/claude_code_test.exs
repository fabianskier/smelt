defmodule Smelt.Runner.ClaudeCodeTest do
  # Every run goes through the fake CLI in test/support/fake_claude.
  use ExUnit.Case, async: true

  alias Smelt.Runner
  alias Smelt.Runner.ClaudeCode
  alias Smelt.Runner.{Event, Result}

  @moduletag :tmp_dir

  @fixtures Path.expand("../../support/fixtures/claude", __DIR__)

  defp fixture(name), do: {"FAKE_CLAUDE_FIXTURE", Path.join(@fixtures, name)}

  defp run(ctx, env, opts \\ []) do
    ClaudeCode.run("prompt", Keyword.merge([cwd: ctx.tmp_dir, env: env], opts))
  end

  # Subscribes, runs in a separate process and returns {run_id, task}.
  defp start_run(ctx, env) do
    run_id = Runner.new_run_id()
    :ok = Runner.subscribe(run_id)
    {run_id, Task.async(fn -> run(ctx, env, run_id: run_id) end)}
  end

  # Collects the events of a run until (and including) :finished.
  defp collect(run_id, acc \\ []) do
    receive do
      {Runner, ^run_id, %Event{type: :finished} = event} -> Enum.reverse([event | acc])
      {Runner, ^run_id, event} -> collect(run_id, [event | acc])
    after
      5_000 -> flunk("run #{run_id} did not finish; got #{inspect(Enum.map(acc, & &1.type))}")
    end
  end

  defp types(events), do: Enum.map(events, & &1.type)

  describe "Requirement: Run an agent with a prompt" do
    test "Scenario: Successful run", ctx do
      assert {:ok, %Result{text: "ok"}} = run(ctx, [fixture("success.jsonl")])
    end

    test "Scenario: Working directory is honored", ctx do
      {real_dir, 0} = System.cmd("pwd", ["-P"], cd: ctx.tmp_dir)

      assert {:ok, %Result{text: text}} = run(ctx, [{"FAKE_CLAUDE_PRINT_CWD", "1"}])
      assert text == String.trim(real_dir)
    end
  end

  describe "Requirement: Stream normalized events" do
    test "Scenario: Events arrive in order", ctx do
      {run_id, task} = start_run(ctx, [fixture("success.jsonl")])

      assert types(collect(run_id)) ==
               [:session_started, :text, :rate_limit, :rate_limit, :result, :finished]

      assert {:ok, _} = Task.await(task)
    end

    test "Scenario: Tool activity is reported", ctx do
      {run_id, task} = start_run(ctx, [fixture("tool_use.jsonl")])
      events = collect(run_id)
      Task.await(task)

      tool_use = Enum.find_index(events, &(&1.type == :tool_use))
      tool_result = Enum.find_index(events, &(&1.type == :tool_result))

      assert tool_use < tool_result
      assert %Event{data: %{name: "Read", input: %{"file_path" => _}}} = Enum.at(events, tool_use)
    end
  end

  describe "Requirement: Broadcast events per run" do
    test "Scenario: Subscriber receives the run's events", ctx do
      run_id = Runner.new_run_id()
      parent = self()

      spawn_link(fn ->
        :ok = Runner.subscribe(run_id)
        send(parent, :subscribed)
        send(parent, {:subscriber_got, collect(run_id)})
      end)

      assert_receive :subscribed
      assert {:ok, _} = run(ctx, [fixture("success.jsonl")], run_id: run_id)

      assert_receive {:subscriber_got, events}, 5_000

      assert types(events) == [
               :session_started,
               :text,
               :rate_limit,
               :rate_limit,
               :result,
               :finished
             ]
    end

    test "Scenario: Runs are isolated", ctx do
      {first_id, first} = start_run(ctx, [fixture("success.jsonl")])
      second_id = Runner.new_run_id()
      second = Task.async(fn -> run(ctx, [fixture("tool_use.jsonl")], run_id: second_id) end)

      assert types(collect(first_id)) ==
               [:session_started, :text, :rate_limit, :rate_limit, :result, :finished]

      Task.await(first)
      Task.await(second)
      refute_received {Runner, ^second_id, _}
    end
  end

  describe "Requirement: Notify subscribers when a run ends" do
    test "Scenario: Subscribers see a successful end", ctx do
      {run_id, task} = start_run(ctx, [fixture("success.jsonl")])
      events = collect(run_id)

      assert {:ok, result} = Task.await(task)
      assert %Event{type: :finished, data: {:ok, ^result}} = List.last(events)
      assert Enum.count(events, &(&1.type == :finished)) == 1
      refute_receive {Runner, ^run_id, _}
    end

    test "Scenario: Subscribers see a failure", ctx do
      {run_id, task} = start_run(ctx, [{"FAKE_CLAUDE_EXIT", "3"}])
      events = collect(run_id)

      assert {:error, {:exit_status, 3, _}} = error = Task.await(task)
      assert %Event{type: :finished, data: ^error} = List.last(events)
    end

    test "Scenario: Subscribers see a stop", ctx do
      {run_id, _os_pid, task} = start_sleeping_run(ctx)

      assert :ok = Runner.stop(run_id)
      events = collect(run_id)

      assert {:error, :stopped} = Task.await(task)
      assert %Event{type: :finished, data: {:error, :stopped}} = List.last(events)
      assert Enum.count(events, &(&1.type == :finished)) == 1
      refute_receive {Runner, ^run_id, _}
    end
  end

  describe "Requirement: Report cost and usage in the result" do
    test "Scenario: Result carries metrics", ctx do
      assert {:ok, result} = run(ctx, [fixture("success.jsonl")])

      assert %Result{
               num_turns: 1,
               duration_ms: 1404,
               session_id: "e915550d-" <> _,
               usage: %{input: 2, output: 4, cache_read: 9064, cache_creation: 12_882}
             } = result

      assert_in_delta result.cost_usd, 0.105, 0.001
    end
  end

  describe "Requirement: Report usage-limit status" do
    test "Scenario: Rate-limit status is surfaced", ctx do
      {run_id, task} = start_run(ctx, [fixture("success.jsonl")])
      events = collect(run_id)
      Task.await(task)

      assert %Event{data: %{utilization: 0.13, resets_at: %DateTime{}}} =
               Enum.find(events, &(&1.type == :rate_limit and &1.data.window == "five_hour"))
    end
  end

  describe "Requirement: Fail with a descriptive error" do
    test "Scenario: Non-zero exit", ctx do
      env = [{"FAKE_CLAUDE_STDERR", "Error: not logged in"}, {"FAKE_CLAUDE_EXIT", "3"}]

      assert {:error, {:exit_status, 3, output}} = run(ctx, env)
      assert "Error: not logged in" in output
    end

    test "Scenario: Agent reports an error result", ctx do
      assert {:error, {:agent_error, %Result{text: "Simulated agent error"}}} =
               run(ctx, [fixture("error_result.jsonl")])
    end

    test "Scenario: No result before exit", ctx do
      assert {:error, :no_result} = run(ctx, [fixture("no_result.jsonl")])
    end

    test "Scenario: Executable not found", ctx do
      run_id = Runner.new_run_id()
      :ok = Runner.subscribe(run_id)

      assert {:error, :executable_not_found} =
               run(ctx, [], executable: "/nonexistent/claude", run_id: run_id)

      assert_receive {Runner, ^run_id,
                      %Event{type: :finished, data: {:error, :executable_not_found}}}
    end

    @tag :capture_log
    test "a crashing session returns an error instead of exiting the caller", ctx do
      pidfile = Path.join(ctx.tmp_dir, "fake.pid")
      run_id = Runner.new_run_id()
      :ok = Runner.subscribe(run_id)
      on_exit(fn -> kill_pidfile(pidfile) end)

      env = [
        {"FAKE_CLAUDE_PIDFILE", pidfile},
        fixture("no_result.jsonl"),
        {"FAKE_CLAUDE_SLEEP", "5"}
      ]

      task = Task.async(fn -> run(ctx, env, run_id: run_id) end)

      # The session is registered before it emits anything.
      assert_receive {Runner, ^run_id, %Event{type: :session_started}}, 5_000
      [{session, _}] = Registry.lookup(Smelt.Runner.Registry, run_id)
      Process.exit(session, :kill)

      assert {:error, {:crashed, :killed}} = Task.await(task)
    end
  end

  describe "Requirement: Tolerate unknown and long output" do
    test "Scenario: Very long line", ctx do
      bytes = 1_100_000
      {run_id, task} = start_run(ctx, [{"FAKE_CLAUDE_LONG_LINE", "#{bytes}"}])
      events = collect(run_id)
      Task.await(task)

      assert %Event{data: %{text: text}} = Enum.find(events, &(&1.type == :text))
      assert byte_size(text) == bytes
    end

    test "Scenario: Unknown or malformed line", ctx do
      assert {:ok, %Result{text: "ok"}} = run(ctx, [fixture("unknown_and_malformed.jsonl")])
    end
  end

  describe "Requirement: Agent does not wait for input" do
    test "Scenario: Agent that reads input", ctx do
      task =
        Task.async(fn ->
          run(ctx, [{"FAKE_CLAUDE_READ_STDIN", "1"}, fixture("success.jsonl")])
        end)

      assert {:ok, {:ok, %Result{}}} = Task.yield(task, 2_000) || Task.shutdown(task)
    end
  end

  describe "Requirement: Clean up the agent process" do
    test "Scenario: Run is stopped", ctx do
      {run_id, os_pid, task} = start_sleeping_run(ctx)
      assert os_alive?(os_pid)

      assert :ok = Runner.stop(run_id)
      assert {:error, :stopped} = Task.await(task)
      refute os_alive?(os_pid)
    end

    test "Scenario: Owner exits", ctx do
      pidfile = Path.join(ctx.tmp_dir, "fake.pid")
      run_id = Runner.new_run_id()
      :ok = Runner.subscribe(run_id)
      on_exit(fn -> kill_pidfile(pidfile) end)

      # The agent ignores SIGTERM, so it takes 2 s to die: if subscribers were
      # told before the kill finished, the agent would still be alive below.
      env = [{"FAKE_CLAUDE_IGNORE_TERM", "1"} | sleeping_env(pidfile)]

      # The owner is a separate process that we kill while the agent runs.
      owner = spawn(fn -> run(ctx, env, run_id: run_id) end)
      assert_receive {Runner, ^run_id, %Event{type: :session_started}}, 5_000
      os_pid = read_pid(pidfile)
      assert os_alive?(os_pid)

      Process.exit(owner, :kill)

      assert_receive {Runner, ^run_id, %Event{type: :finished, data: {:error, :stopped}}}, 5_000
      refute os_alive?(os_pid)
    end

    @tag :slow
    test "an agent that ignores SIGTERM is killed before the caller hears it stopped", ctx do
      {run_id, os_pid, task} = start_sleeping_run(ctx, [{"FAKE_CLAUDE_IGNORE_TERM", "1"}])

      started = System.monotonic_time(:millisecond)
      stopper = Task.async(fn -> Runner.stop(run_id) end)

      # The caller must only hear :stopped once the agent is really dead.
      assert {:error, :stopped} = Task.await(task)
      refute os_alive?(os_pid)
      assert System.monotonic_time(:millisecond) - started >= 2_000
      assert :ok = Task.await(stopper)
    end

    test "a supervisor shutdown of the session terminates the agent", ctx do
      {run_id, os_pid, task} = start_sleeping_run(ctx)
      [{session, _}] = Registry.lookup(Smelt.Runner.Registry, run_id)

      :ok = DynamicSupervisor.terminate_child(Smelt.Runner.Supervisor, session)

      refute os_alive?(os_pid)
      assert {:error, {:crashed, _}} = Task.await(task)
    end

    test "stopping an unknown run returns not found" do
      assert {:error, :not_found} = Runner.stop(Runner.new_run_id())
    end
  end

  # Starts a run whose agent emits a few events and then sleeps.
  # Returns {run_id, agent_os_pid, task}; the caller is subscribed.
  defp start_sleeping_run(ctx, extra_env \\ []) do
    pidfile = Path.join(ctx.tmp_dir, "fake.pid")
    on_exit(fn -> kill_pidfile(pidfile) end)

    {run_id, task} = start_run(ctx, extra_env ++ sleeping_env(pidfile))
    assert_receive {Runner, ^run_id, %Event{type: :session_started}}, 5_000
    {run_id, read_pid(pidfile), task}
  end

  defp sleeping_env(pidfile) do
    [{"FAKE_CLAUDE_PIDFILE", pidfile}, fixture("no_result.jsonl"), {"FAKE_CLAUDE_SLEEP", "30"}]
  end

  # The fake writes its pidfile before any output, so it exists once
  # :session_started has been received.
  defp read_pid(pidfile), do: pidfile |> File.read!() |> String.trim()

  defp os_alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    status == 0
  end

  defp kill_pidfile(pidfile) do
    with {:ok, pid} <- File.read(pidfile),
         do: System.cmd("kill", ["-9", String.trim(pid)], stderr_to_stdout: true)
  end
end
