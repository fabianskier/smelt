defmodule Mix.Tasks.Smelt.TaskUsageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Smelt.TaskRunFixtures

  alias Mix.Tasks.Smelt.Task, as: SmeltTask

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir)
    %{repo: repo, opts: opts(tmp_dir, [{"FAKE_AGENT_FIRST", commit_app()}])}
  end

  defp records(opts) do
    opts[:root]
    |> Path.join("usage.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  describe "Requirement: Keep a usage record" do
    test "Scenario: Usage recorded", %{repo: repo, opts: opts} do
      output = capture_io("n\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

      assert output =~ "Token use: 3 turns, $0.25"

      assert [record] = records(opts)
      assert record["repo"] == repo
      assert record["change"] == "add-x"
      assert record["task_id"] == "1.1"
      assert record["status"] == "passed"
      assert record["turns"] == 3
      assert record["cost_usd"] == 0.25

      assert record["tokens"] == %{
               "input" => 0,
               "cache_creation" => 0,
               "cache_read" => 0,
               "output" => 0
             }

      assert record["tools"] == []
      assert {:ok, _at, 0} = DateTime.from_iso8601(record["at"])
    end

    test "Scenario: Earlier records are kept", %{repo: repo, opts: opts} do
      capture_io("y\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

      # Task 1.1 is merged, so its checkbox is still open in the fixture: run it again.
      capture_io("n\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

      assert [first, second] = records(opts)
      assert first["task_id"] == "1.1"
      assert second["task_id"] == "1.1"
    end
  end
end
