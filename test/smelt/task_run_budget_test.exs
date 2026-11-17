defmodule Smelt.TaskRunBudgetTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Smelt.TaskRunFixtures

  alias Mix.Tasks.Smelt.Task, as: SmeltTask

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{repo: project!(tmp_dir)}
  end

  # The value after `--max-budget-usd` in a fake agent call, or nil.
  defp budget(args) do
    case Enum.drop_while(args, &(&1 != "--max-budget-usd")) do
      ["--max-budget-usd", usd | _] -> usd
      [] -> nil
    end
  end

  describe "Requirement: Cap the agent's spending" do
    test "Scenario: Default budget", %{repo: repo, tmp_dir: tmp_dir} do
      opts = opts(tmp_dir, [{"FAKE_AGENT_FIRST", commit_app()}])

      capture_io("n\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

      assert [args] = agent_calls(tmp_dir)
      assert budget(args) == "5.0"
    end

    test "Scenario: Budget from the command line", %{repo: repo, tmp_dir: tmp_dir} do
      opts =
        opts(tmp_dir, [
          {"FAKE_AGENT_FIRST", break_test()},
          {"FAKE_AGENT_RESUMED", restore_test()}
        ])

      capture_io("n\n", fn ->
        SmeltTask.run([repo, "add-x", "1.1", "--max-budget", "1.5"], opts)
      end)

      assert [first, resumed] = agent_calls(tmp_dir)
      assert budget(first) == "1.5"
      assert budget(resumed) == "1.5"
    end
  end
end
