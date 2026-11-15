defmodule Smelt.TaskRunTest do
  use ExUnit.Case, async: true

  import Smelt.TaskRunFixtures

  alias Smelt.GitRepo
  alias Smelt.TaskRun
  alias Smelt.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{repo: project!(tmp_dir)}
  end

  describe "Requirement: Run a task end to end" do
    test "Scenario: Task passes the gate", %{repo: repo, tmp_dir: tmp_dir} do
      opts = opts(tmp_dir, [{"FAKE_AGENT_FIRST", commit_app()}])

      assert {:ok, %TaskRun{status: :passed} = run} = TaskRun.run(repo, "add-x", "1.1", opts)

      assert run.task == %{id: "1.1", description: "Add the app module"}
      assert run.gate.status == :pass
      assert run.cost_usd == 0.25
      assert [%{number: 1, result: {:ok, %{session_id: "fake-session"}}}] = run.attempts
      assert {:ok, ws} = Workspace.fetch(repo, "add-x", "1.1", root: opts[:root])
      assert ws == run.workspace
      assert File.read!(Path.join(ws.path, "lib/app.ex")) == "app\n"
    end
  end

  describe "Requirement: Read the task from the base commit" do
    test "Scenario: Unknown task", %{repo: repo, tmp_dir: tmp_dir} do
      opts = opts(tmp_dir)

      assert TaskRun.run(repo, "add-x", "9.9", opts) == {:error, :task_not_found}

      assert agent_calls(tmp_dir) == []
      assert Workspace.fetch(repo, "add-x", "9.9", root: opts[:root]) == {:error, :not_found}
      assert GitRepo.branches(repo) == ["main"]
    end

    test "Scenario: Task already done", %{repo: repo, tmp_dir: tmp_dir} do
      opts = opts(tmp_dir)

      assert TaskRun.run(repo, "add-x", "1.2", opts) == {:error, :task_done}

      assert agent_calls(tmp_dir) == []
      assert GitRepo.branches(repo) == ["main"]
    end

    test "an unknown change", %{repo: repo, tmp_dir: tmp_dir} do
      assert TaskRun.run(repo, "add-y", "1.1", opts(tmp_dir)) == {:error, :change_not_found}
      assert GitRepo.branches(repo) == ["main"]
    end
  end

  describe "Requirement: Instruct the agent" do
    test "Scenario: Prompt describes the task", %{repo: repo, tmp_dir: tmp_dir} do
      {:ok, _} = TaskRun.run(repo, "add-x", "1.1", opts(tmp_dir))

      [args] = agent_calls(tmp_dir)
      prompt = prompt(args)

      assert prompt =~ ~s("add-x")
      assert prompt =~ "Task 1.1: Add the app module"
      assert prompt =~ "openspec/changes/add-x/tasks.md"
    end
  end

  describe "Requirement: Limit the agent's permissions" do
    test "Scenario: Agent permissions", %{repo: repo, tmp_dir: tmp_dir} do
      {:ok, _} = TaskRun.run(repo, "add-x", "1.1", opts(tmp_dir))

      [args] = agent_calls(tmp_dir)

      assert after_flag(args, "--allowedTools") == [
               "Read",
               "Edit",
               "Write",
               "Glob",
               "Grep",
               "Bash(mix:*)",
               "Bash(git:*)",
               "Bash(sh .smelt/checks.sh)"
             ]

      assert after_flag(args, "--disallowedTools") == ["Bash(git push:*)"]
      assert after_flag(args, "--permission-mode") == ["acceptEdits"]
    end
  end

  describe "Requirement: Retry once after a failed gate" do
    test "Scenario: Fixed on retry", %{repo: repo, tmp_dir: tmp_dir} do
      opts =
        opts(tmp_dir, [
          {"FAKE_AGENT_FIRST", break_test()},
          {"FAKE_AGENT_RESUMED", restore_test()}
        ])

      assert {:ok, %TaskRun{status: :passed} = run} = TaskRun.run(repo, "add-x", "1.1", opts)

      assert [%{number: 1}, %{number: 2}] = run.attempts
      assert run.cost_usd == 0.5

      [first, second] = agent_calls(tmp_dir)
      refute "--resume" in first
      assert after_flag(second, "--resume") == ["fake-session"]
      assert prompt(second) =~ "protected_files: you changed protected files: test/app_test.exs"
    end

    test "Scenario: Fails twice", %{repo: repo, tmp_dir: tmp_dir} do
      opts =
        opts(tmp_dir, [{"FAKE_AGENT_FIRST", break_test()}, {"FAKE_AGENT_RESUMED", "true"}])

      assert {:ok, %TaskRun{status: :gate_failed} = run} = TaskRun.run(repo, "add-x", "1.1", opts)

      assert length(run.attempts) == 2
      assert length(agent_calls(tmp_dir)) == 2
      assert run.gate.status == :fail
      assert %{status: :fail} = Smelt.Gate.Result.rule(run.gate, :protected_files)
    end
  end

  describe "Requirement: Stop when the agent fails" do
    test "Scenario: Agent fails", %{repo: repo, tmp_dir: tmp_dir} do
      id = TaskRun.new_id()
      :ok = TaskRun.subscribe(id)
      opts = [id: id] ++ opts(tmp_dir, [{"FAKE_AGENT_EXIT", "1"}])

      assert {:ok, %TaskRun{status: :agent_failed} = run} =
               TaskRun.run(repo, "add-x", "1.1", opts)

      assert [%{result: {:error, _}}] = run.attempts
      assert run.gate == nil
      refute_received {TaskRun, ^id, {:gate_started, _}}
      assert {:ok, _} = Workspace.fetch(repo, "add-x", "1.1", root: opts[:root])
    end
  end

  describe "Requirement: Report progress as events" do
    test "Scenario: Progress events in order", %{repo: repo, tmp_dir: tmp_dir} do
      id = TaskRun.new_id()
      :ok = TaskRun.subscribe(id)
      opts = [id: id] ++ opts(tmp_dir, [{"FAKE_AGENT_FIRST", commit_app()}])

      {:ok, run} = TaskRun.run(repo, "add-x", "1.1", opts)

      agent_run_id = TaskRun.agent_run_id(id, 1)

      assert [
               {:workspace_created, %Workspace{}},
               {:agent_started, 1, ^agent_run_id},
               {:agent_finished, 1, {:ok, _}},
               {:gate_started, 1},
               {:gate_finished, 1, %{status: :pass}},
               {:finished, {:ok, ^run}}
             ] = events(id)
    end
  end

  # Drains the mailbox and returns this run's events, in order.
  defp events(id) do
    receive do
      {TaskRun, ^id, event} -> [event | events(id)]
    after
      0 -> []
    end
  end

  defp prompt(args), do: hd(after_flag(args, "-p"))

  # The arguments that follow `flag`, up to the next argument starting with `--`.
  defp after_flag(args, flag) do
    args
    |> Enum.drop_while(&(&1 != flag))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "--")))
  end
end
