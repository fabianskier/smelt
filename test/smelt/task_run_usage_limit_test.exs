defmodule Smelt.TaskRunUsageLimitTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Smelt.TaskRunFixtures

  alias Mix.Tasks.Smelt.Task, as: SmeltTask
  alias Smelt.TaskRun
  alias Smelt.Workspace

  @moduletag :tmp_dir

  @limited_agent Path.expand("../support/fake_agent_limited", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    opts = opts(tmp_dir)
    opts = Keyword.update!(opts, :runner, &Keyword.put(&1, :executable, @limited_agent))
    %{repo: project!(tmp_dir), opts: opts}
  end

  describe "Requirement: Stop on a usage limit" do
    test "Scenario: Usage limit stops the task", %{repo: repo, opts: opts} do
      output =
        capture_io(fn ->
          assert catch_exit(SmeltTask.run([repo, "add-x", "1.1"], opts)) == {:shutdown, 1}
        end)

      assert output =~ "stopped by a usage limit: Fable 5.2 requires usage credits"
      assert output =~ "Task stopped by a usage limit ($0.91), not by the work."
      refute output =~ "▶ Gate"
      assert {:ok, _ws} = Workspace.fetch(repo, "add-x", "1.1", root: opts[:root])
    end
  end

  describe "Requirement: Count the cost of failed attempts" do
    test "Scenario: Cost of a stopped attempt", %{repo: repo, opts: opts} do
      assert {:ok, %TaskRun{status: :usage_limited} = run} =
               TaskRun.run(repo, "add-x", "1.1", opts)

      assert run.cost_usd == 0.91
      assert run.gate == nil
      assert [%{result: {:error, {:usage_limit, _result}}}] = run.attempts
    end
  end
end
