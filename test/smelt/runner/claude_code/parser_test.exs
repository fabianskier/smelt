defmodule Smelt.Runner.ClaudeCode.ParserTest do
  use ExUnit.Case, async: true

  alias Smelt.Runner.ClaudeCode.Parser
  alias Smelt.Runner.{Event, Result}

  @fixtures Path.expand("../../../support/fixtures/claude", __DIR__)

  defp parse_fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.stream!()
    |> Enum.map(&String.trim_trailing(&1, "\n"))
    |> Enum.flat_map(fn line ->
      case Parser.parse_line(line) do
        {:ok, events} -> events
        {:error, :invalid_json} -> []
      end
    end)
  end

  defp types(events), do: Enum.map(events, & &1.type)

  describe "success.jsonl" do
    test "maps to session started, text, rate limits and result, in order" do
      assert types(parse_fixture("success.jsonl")) ==
               [:session_started, :text, :rate_limit, :rate_limit, :result]
    end

    test "session started carries session id, model and cwd" do
      [%Event{type: :session_started, data: data} | _] = parse_fixture("success.jsonl")

      assert %{session_id: "e915550d-" <> _, model: model, cwd: "/tmp/project"} = data
      assert is_binary(model)
    end

    test "text carries the assistant text" do
      assert %Event{data: %{text: "ok"}} =
               Enum.find(parse_fixture("success.jsonl"), &(&1.type == :text))
    end

    test "rate limit reports each window with utilization and reset time" do
      windows =
        "success.jsonl"
        |> parse_fixture()
        |> Enum.filter(&(&1.type == :rate_limit))
        |> Map.new(&{&1.data.window, &1.data})

      assert %{utilization: 0.13, resets_at: %DateTime{}, status: "allowed"} =
               windows["five_hour"]

      assert %{utilization: 0.09, resets_at: %DateTime{}} = windows["seven_day"]
    end

    test "result carries text, cost, usage, turns, duration and session id" do
      %Event{data: %{is_error: false, subtype: "success", result: result}} =
        List.last(parse_fixture("success.jsonl"))

      assert %Result{
               text: "ok",
               num_turns: 1,
               duration_ms: 1404,
               session_id: "e915550d-" <> _,
               usage: %{input: 2, output: 4, cache_read: 9064, cache_creation: 12_882}
             } = result

      assert_in_delta result.cost_usd, 0.105, 0.001
    end
  end

  describe "tool_use.jsonl" do
    test "reports tool use followed by its tool result" do
      events = parse_fixture("tool_use.jsonl")

      assert types(events) == [
               :session_started,
               :tool_use,
               :rate_limit,
               :rate_limit,
               :tool_result,
               :text,
               :rate_limit,
               :rate_limit,
               :result
             ]

      %Event{data: tool_use} = Enum.find(events, &(&1.type == :tool_use))
      %Event{data: tool_result} = Enum.find(events, &(&1.type == :tool_result))

      assert %{name: "Read", input: %{"file_path" => "/tmp/project/hello.txt"}} = tool_use
      assert tool_result.tool_use_id == tool_use.id
      assert tool_result.content =~ "smelt"
      assert tool_result.is_error == false
    end
  end

  describe "error_result.jsonl" do
    test "marks the result as an error" do
      assert %Event{
               type: :result,
               data: %{is_error: true, subtype: "error_during_execution"} = data
             } =
               List.last(parse_fixture("error_result.jsonl"))

      assert data.result.text == "Simulated agent error"
    end
  end

  describe "unknown and malformed lines" do
    test "unknown event types produce no events" do
      assert Parser.parse(%{"type" => "some_future_event", "payload" => %{}}) == []
      assert {:ok, []} = Parser.parse_line(~s({"type":"some_future_event"}))
    end

    test "lines that are not a JSON object are reported as invalid" do
      assert {:error, :invalid_json} = Parser.parse_line("this line is not json {")
      assert {:error, :invalid_json} = Parser.parse_line("Error: not logged in")
      assert {:error, :invalid_json} = Parser.parse_line("[1, 2]")
    end

    test "the fixture still yields the same events as success.jsonl" do
      assert types(parse_fixture("unknown_and_malformed.jsonl")) ==
               types(parse_fixture("success.jsonl"))
    end

    test "unknown content blocks are skipped" do
      msg = %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "thinking"}, %{"type" => "text", "text" => "hi"}]
        }
      }

      assert [%Event{type: :text, data: %{text: "hi"}}] = Parser.parse(msg)
    end
  end

  describe "rate limit without unified windows" do
    test "falls back to the single reported window" do
      msg = %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "rateLimitType" => "five_hour",
          "resetsAt" => 0,
          "status" => "allowed"
        }
      }

      assert [
               %Event{
                 data: %{
                   window: "five_hour",
                   utilization: nil,
                   resets_at: ~U[1970-01-01 00:00:00Z]
                 }
               }
             ] =
               Parser.parse(msg)
    end
  end
end
