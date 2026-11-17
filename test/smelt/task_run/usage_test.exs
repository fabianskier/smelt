defmodule Smelt.TaskRun.UsageTest do
  use ExUnit.Case, async: true

  alias Smelt.Runner.Event
  alias Smelt.Runner.Result
  alias Smelt.TaskRun.Usage

  defp tool_use(id, name), do: %Event{type: :tool_use, data: %{id: id, name: name, input: %{}}}

  defp tool_result(id, content) do
    %Event{type: :tool_result, data: %{tool_use_id: id, content: content, is_error: false}}
  end

  defp result(usage, turns, cost) do
    %Event{
      type: :result,
      data: %{
        is_error: false,
        subtype: "success",
        result: %Result{text: "done", usage: usage, num_turns: turns, cost_usd: cost}
      }
    }
  end

  defp record(events), do: Enum.reduce(events, Usage.new(), &Usage.record(&2, &1))

  defp attempt do
    [
      %Event{type: :session_started, data: %{session_id: "s", model: "claude-test", cwd: "/tmp"}},
      %Event{type: :text, data: %{text: "working"}},
      tool_use("t1", "Read"),
      tool_result("t1", String.duplicate("a", 1_200)),
      tool_use("t2", "Bash"),
      tool_result("t2", [%{"type" => "text", "text" => String.duplicate("b", 30_000)}]),
      tool_use("t3", "Read"),
      tool_result("t3", String.duplicate("c", 300)),
      result(%{input: 40, cache_creation: 12_000, cache_read: 1_234_567, output: 900}, 7, 0.5)
    ]
  end

  describe "Requirement: Report token use" do
    test "Scenario: Token report printed" do
      lines = attempt() |> record() |> Usage.lines()

      assert [header, counts, _title, first_tool, second_tool] = lines
      assert header == "Token use: 7 turns, $0.50, claude-test"
      assert counts =~ "input 40"
      assert counts =~ "cache write 12,000"
      assert counts =~ "cache read 1,234,567"
      assert counts =~ "output 900"
      assert first_tool =~ ~r/Bash\s+1 calls\s+30,000 chars/
      assert second_tool =~ ~r/Read\s+2 calls\s+1,500 chars/
    end

    test "Scenario: Attempts are summed" do
      second = [tool_use("t4", "Edit"), result(%{input: 10, output: 100}, 3, 0.25)]
      usage = record(attempt() ++ second)

      assert usage.turns == 10
      assert usage.cost_usd == 0.75

      assert usage.tokens == %{
               input: 50,
               cache_creation: 12_000,
               cache_read: 1_234_567,
               output: 1_000
             }

      assert Enum.map(Usage.tools(usage), &{&1.name, &1.calls}) == [
               {"Bash", 1},
               {"Read", 2},
               {"Edit", 1}
             ]
    end

    test "a result for an unknown tool call and events without usage change nothing" do
      usage = record([tool_result("missing", "x"), %Event{type: :finished, data: :ok}])

      assert usage == Usage.new()

      assert Usage.lines(usage) == [
               "Token use: 0 turns, $0.00",
               "  input 0 · cache write 0 · cache read 0 · output 0"
             ]
    end
  end
end
