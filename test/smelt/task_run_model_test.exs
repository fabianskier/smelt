defmodule Smelt.TaskRunModelTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Smelt.TaskRunFixtures

  alias Mix.Tasks.Smelt.Task, as: SmeltTask

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{repo: project!(tmp_dir)}
  end

  # The value after `--model` in a fake agent call, or nil.
  defp model(args) do
    case Enum.drop_while(args, &(&1 != "--model")) do
      ["--model", name | _] -> name
      [] -> nil
    end
  end

  describe "Requirement: Choose the agent's model" do
    test "Scenario: Model passed to the agent", %{repo: repo, tmp_dir: tmp_dir} do
      opts =
        opts(tmp_dir, [
          {"FAKE_AGENT_FIRST", break_test()},
          {"FAKE_AGENT_RESUMED", restore_test()}
        ])

      output =
        capture_io("n\n", fn ->
          SmeltTask.run([repo, "add-x", "1.1", "--model", "sonnet"], opts)
        end)

      assert output =~ "Merge into main? [y/N]"
      assert [first, resumed] = agent_calls(tmp_dir)
      assert model(first) == "sonnet"
      assert model(resumed) == "sonnet"
      assert "--resume" in resumed
    end

    test "Scenario: No model by default", %{repo: repo, tmp_dir: tmp_dir} do
      opts = opts(tmp_dir, [{"FAKE_AGENT_FIRST", commit_app()}])

      capture_io("n\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

      assert [args] = agent_calls(tmp_dir)
      refute "--model" in args
    end
  end
end
