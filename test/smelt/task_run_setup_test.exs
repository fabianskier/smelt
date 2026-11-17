defmodule Smelt.TaskRunSetupTest do
  use ExUnit.Case, async: true

  import Smelt.TaskRunFixtures

  alias Smelt.GitRepo
  alias Smelt.TaskRun

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{repo: project!(tmp_dir)}
  end

  # Adds a setup script to the project's base branch.
  defp add_setup!(repo, script) do
    GitRepo.commit!(repo, "chore: add setup", %{".smelt/setup.sh" => script})
  end

  # Runs the task and returns the events a subscriber got, in order.
  defp run_and_collect(repo, opts) do
    id = TaskRun.new_id()
    :ok = TaskRun.subscribe(id)
    result = TaskRun.run(repo, "add-x", "1.1", [id: id] ++ opts)
    {result, collect(id, [])}
  end

  defp collect(id, acc) do
    receive do
      {TaskRun, ^id, {:finished, _}} -> Enum.reverse(acc)
      {TaskRun, ^id, event} -> collect(id, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp names(events) do
    Enum.map(events, fn
      event when is_atom(event) -> event
      event -> elem(event, 0)
    end)
  end

  describe "Requirement: Prepare the workspace before the agent" do
    test "Scenario: Setup runs before the agent", %{repo: repo, tmp_dir: tmp_dir} do
      add_setup!(repo, "echo prepared > _prepared\n")

      # The agent fails unless the setup's file is already there.
      opts = opts(tmp_dir, [{"FAKE_AGENT_FIRST", "test -f _prepared && rm _prepared"}])

      {result, events} = run_and_collect(repo, opts)

      assert {:ok, %TaskRun{status: :passed}} = result

      assert names(events) == [
               :workspace_created,
               :setup_started,
               :setup_finished,
               :agent_started,
               :agent_finished,
               :gate_started,
               :gate_finished
             ]

      assert {:setup_finished, :ok} in events
    end

    test "Scenario: Failed setup does not stop the task", %{repo: repo, tmp_dir: tmp_dir} do
      add_setup!(repo, "echo cannot prepare\nexit 3\n")

      {result, events} = run_and_collect(repo, opts(tmp_dir))

      assert {:ok, %TaskRun{}} = result
      assert [_call] = agent_calls(tmp_dir)

      assert [{:setup_finished, {:error, details}}] =
               Enum.filter(events, &match?({:setup_finished, _}, &1))

      assert details.reason == :failed
      assert details.exit_status == 3
      assert details.output =~ "cannot prepare"
    end

    test "Scenario: No setup script", %{repo: repo, tmp_dir: tmp_dir} do
      {_result, events} = run_and_collect(repo, opts(tmp_dir))

      refute :setup_started in names(events)
      refute :setup_finished in names(events)
    end
  end
end
